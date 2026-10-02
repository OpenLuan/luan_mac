#import "LuaBridge.h"

#import <pthread.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <event2/event.h>
#import <sqlite3.h>

#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"
#import "caplua.h"
#include "runtime/loop.h"
#include "runtime/coro.h"
#import "luauser.h"
#import "pal.h"
#import <event2/dns.h>

#import "LuaState.h"
#import "LuaError.h"

extern void incrRef(lua_State *L);
extern void decrRef(lua_State *L);
extern void fan_clear_lua_states(void);

static int luan_process_metrics(lua_State *L);

// Globals historically defined by the tunnel host; provide stubs for the Mac app.
_Atomic size_t libevent_mem_total = 0;
BOOL pp_ipv6 = NO;

// MARK: - Metrics samplers

// Lua VM 内存字节数, 由 lua 自定义 allocator (caplua.c:242 _Atomic size_t lua_mem_total)
// 在每次 alloc/realloc/free 时累加. UI 线程直接 atomic_load 即可, 无锁, 不需要 evtimer.
extern _Atomic size_t lua_mem_total;

// MARK: - runtime/ is a plain Lua tree from scripts/build.sh (entry: core.lua).


// MARK: - LuaFan v2 coroutine boundary
// All native callbacks resume through fan_coro_resume so the v2 lifetime
// and Lua ABI rules remain centralized in the runtime.

// MARK: - print 重定向: 加时间戳后追加到日志文件

static FILE *g_logFile = NULL;
static BOOL g_logToStderr = NO;

void LuanSetLogToStderr(BOOL enabled) {
    g_logToStderr = enabled;
}

void LuanOpenLogFile(NSString *documentRoot) {
    if (g_logFile) { fclose(g_logFile); g_logFile = NULL; }
    NSString *logPath = [documentRoot stringByAppendingPathComponent:@"luan.log"];
    // 每次启动丢弃旧日志, 避免日志无限增长
    g_logFile = fopen([logPath fileSystemRepresentation], "w");
    if (g_logFile) {
        int fd = fileno(g_logFile);
        int flags = fcntl(fd, F_GETFD);
        if (flags >= 0) {
            (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
        }
    }
}

void LuanCloseLogFile(void) {
    if (g_logFile) { fclose(g_logFile); g_logFile = NULL; }
}

void LuanLogWrite(NSString *msg) {
    NSLog(@"%@", msg);
    if (g_logFile) {
        fputs([msg UTF8String], g_logFile);
        fflush(g_logFile);
    }
}

// Always surface bridge diagnostics: outputHandler (app UI) + log file + stderr when CLI.
static void luan_emit(NSString *msg) {
    if (!msg) return;
    if (g_logFile) {
        fputs([msg UTF8String], g_logFile);
        fflush(g_logFile);
    }
    if (g_logToStderr) {
        fprintf(stderr, "%s", [msg UTF8String]);
        fflush(stderr);
    } else {
        NSLog(@"%@", msg);
    }
}

static int luan_lua_print(lua_State *L) {
    @autoreleasepool {
    int n = lua_gettop(L);
    lua_getglobal(L, "tostring");

    NSMutableString *msg = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        size_t size = 0;
        const char *s = luaL_checklstring(L, -1, &size);
        if (s == NULL) {
            return luaL_error(L, "'tostring' must return a string to 'print'");
        }
        if (i > 1) [msg appendString:@"\t"];
        [msg appendString:[[NSString alloc] initWithBytes:s length:size encoding:NSUTF8StringEncoding] ?: @""];
        lua_pop(L, 1);
    }
    lua_pop(L, 1);

    // 时间戳
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm_info;
    localtime_r(&tv.tv_sec, &tm_info);
    char ts[32];
    snprintf(ts, sizeof(ts), "%02d:%02d:%02d.%03d",
             tm_info.tm_hour, tm_info.tm_min, tm_info.tm_sec,
             (int)(tv.tv_usec / 1000));

    NSString *line = [NSString stringWithFormat:@"[%s] [lua] %@\n", ts, msg];
    luan_emit(line);
    return 0;
    }
}

// MARK: - LuaBridge

@interface LuaBridge () {
    LuaState *_state;
    dispatch_queue_t _eventQueue;  // serial queue: lua + fan.loop
}
@end

@implementation LuaBridge

+ (void)initialize {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // LuaFan v2 owns coroutine transitions through fan_coro_resume.
        // The event loop is entered explicitly on the serialized Lua queue.
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _eventQueue = dispatch_queue_create("com.luanmac.event", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)runWithDocumentRoot:(NSString *)documentRoot
                        env:(NSDictionary<NSString *, NSString *> *)env {
    LuanOpenLogFile(documentRoot);

    // Inject configuration from the SwiftUI/CLI host into the process env.
    for (NSString *k in env) {
        NSString *v = env[k];
        if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) continue;
        setenv([k UTF8String], [v UTF8String], 1);
    }

    dispatch_sync(_eventQueue, ^{
        [self _runOnEventQueueWithDocumentRoot:documentRoot];
    });
}

- (void)runScriptWithDocumentRoot:(NSString *)documentRoot
                               env:(NSDictionary<NSString *, NSString *> *)env {
    NSMutableDictionary *scriptEnv = [NSMutableDictionary dictionaryWithDictionary:env ?: @{}];
    if (!scriptEnv[@"LUAN_EXEC_SCRIPT"] && !scriptEnv[@"LUAN_EXEC_CODE"]) {
        scriptEnv[@"LUAN_EXEC_CODE"] = @"return true";
    }
    [self runWithDocumentRoot:documentRoot env:scriptEnv];
}

- (void)_runOnEventQueueWithDocumentRoot:(NSString *)documentRoot {
    (void)fan_loop_base();

    // Process-wide SQLite soft heap limit. 0 disables the limit; any positive
    // value is interpreted as megabytes. Applies to every sqlite3.open() that
    // follows (system .system.db, sandbox user dbs, in-memory dbs). Must run
    // before any sqlite3_open so the limit covers all connections.
    const char *envSoftHeap = getenv("SQLITE_SOFT_HEAP_MB");
    long long softHeapMB = envSoftHeap ? atoll(envSoftHeap) : 0;
    if (softHeapMB > 0) {
        sqlite3_int64 bytes = (sqlite3_int64)softHeapMB * 1024 * 1024;
        sqlite3_soft_heap_limit64(bytes);
        NSString *msg = [NSString stringWithFormat:@"[sqlite] soft_heap_limit=%lld MB\n", softHeapMB];
        if (self.outputHandler) self.outputHandler(msg);
    }

    // 诊断: dump evdns 状态
    struct evdns_base *db = fan_loop_dnsbase();
    int ns_count = db ? evdns_base_count_nameservers(db) : -1;
    NSString *dnsMsg = [NSString stringWithFormat:@"[evdns] dnsbase=%p, nameservers=%d\n",
                        db, ns_count];
    if (self.outputHandler) self.outputHandler(dnsMsg);

    NSFileManager *fm = [NSFileManager defaultManager];

    // runtime/ plain Lua tree (entry: core.lua) from scripts/build.sh.
    // Priority: documentRoot/runtime > legacy documentRoot/service > app bundle.
    // If documentRoot/runtime doesn't exist, symlink it to the bundle copy.
    NSString *localRuntimeDir = [documentRoot stringByAppendingPathComponent:@"runtime"];
    NSString *legacyServiceDir = [documentRoot stringByAppendingPathComponent:@"service"];
    NSString *bundleRuntime = [[NSBundle mainBundle] pathForResource:@"runtime" ofType:nil];
    if (!bundleRuntime) {
        // Legacy bundle resource name during transition.
        bundleRuntime = [[NSBundle mainBundle] pathForResource:@"service" ofType:nil];
    }

    BOOL (^hasCore)(NSString *) = ^BOOL(NSString *dir) {
        return dir && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"core.lua"]];
    };

    NSString *linkTarget = nil;
    if (hasCore(bundleRuntime)) {
        linkTarget = bundleRuntime;
    } else if (hasCore(legacyServiceDir)) {
        // Prefer promoting legacy documentRoot/service → runtime symlink target path.
        linkTarget = legacyServiceDir;
    }

    // A workspace runtime symlink may still resolve to a valid but stale
    // runtime from another app/build path. Refresh it to this app's bundle
    // runtime whenever the current target is available.
    BOOL localRuntimeIsSymlink = [fm destinationOfSymbolicLinkAtPath:localRuntimeDir error:nil] != nil;
    if (localRuntimeIsSymlink && linkTarget) {
        [fm removeItemAtPath:localRuntimeDir error:nil];
        [fm createSymbolicLinkAtPath:localRuntimeDir withDestinationPath:linkTarget error:nil];
    } else if (!hasCore(localRuntimeDir) && linkTarget) {
        [fm createDirectoryAtPath:documentRoot withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:localRuntimeDir]) {
            [fm removeItemAtPath:localRuntimeDir error:nil];
        }
        [fm createSymbolicLinkAtPath:localRuntimeDir withDestinationPath:linkTarget error:nil];
    }

    NSString *runtimeDir = nil;
    if (hasCore(localRuntimeDir)) {
        runtimeDir = localRuntimeDir;
    } else if (hasCore(bundleRuntime)) {
        runtimeDir = bundleRuntime;
    } else if (hasCore(legacyServiceDir)) {
        runtimeDir = legacyServiceDir;
    }
    if (!runtimeDir) {
        if (self.outputHandler) {
            self.outputHandler(@"!! runtime/ missing or has no core.lua (run scripts/build_runtime.sh)\n");
        }
        return;
    }

    if (self.outputHandler) {
        NSString *msg = [NSString stringWithFormat:@"[runtime] using: %@\n", runtimeDir];
        self.outputHandler(msg);
    }

    lua_State *L = utlua_open_state();
    incrRef(L);

    [fm createDirectoryAtPath:documentRoot withIntermediateDirectories:YES attributes:nil error:nil];
    // 预建运行时常用子目录, lua 端 (sqlite_pool / workspace_agent / api 等) 不需要再各自 mkdir.
    [fm createDirectoryAtPath:[documentRoot stringByAppendingPathComponent:@"workspaces"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *documentRootSlash = [documentRoot hasSuffix:@"/"] ? documentRoot : [documentRoot stringByAppendingString:@"/"];
    NSString *runtimeDirSlash = [runtimeDir hasSuffix:@"/"] ? runtimeDir : [runtimeDir stringByAppendingString:@"/"];

    // groupRoot / serviceRoot: legacy aliases; keep equal to runtime root.
    lua_pushstring(L, [runtimeDirSlash fileSystemRepresentation]);
    lua_setglobal(L, "groupRoot");
    lua_pushstring(L, [runtimeDirSlash fileSystemRepresentation]);
    lua_setglobal(L, "runtimeRoot");
    lua_pushstring(L, [runtimeDirSlash fileSystemRepresentation]);
    lua_setglobal(L, "serviceRoot"); // legacy alias
    lua_pushstring(L, [runtimeDirSlash fileSystemRepresentation]);
    lua_setglobal(L, "WORKDIR");
    // Plain Lua tree from build.sh.
    lua_pushstring(L, ".lua");
    lua_setglobal(L, "MODULE_EXT");
    // "bt": text or binary chunks (disk sources are text).
    lua_pushstring(L, "bt");
    lua_setglobal(L, "MODULE_LOAD_MODE");
    lua_pushstring(L, [documentRootSlash fileSystemRepresentation]);
    lua_setglobal(L, "documentRoot");

    pal_init();
    pal_set_runtime_root([runtimeDirSlash fileSystemRepresentation]);
    pal_set_document_root([documentRootSlash fileSystemRepresentation]);
    pal_lua_bridge_register(L);

    // package.path: merged runtime/ tree (?.lua and ?/init.lua).
    NSString *luaPath = [NSString stringWithFormat:
        @";%@?.lua;%@?/init.lua", runtimeDirSlash, runtimeDirSlash];
    lua_getglobal(L, "package");
    lua_pushstring(L, [luaPath UTF8String]);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);

    lua_register(L, "print", luan_lua_print);
    lua_register(L, "luan_process_metrics", luan_process_metrics);

    _state = [[LuaState alloc] initWithState:L];

    // fan.http HTTPS CA bundle paths (cacert.pem under runtime/).
    NSString *caInfo = [runtimeDir stringByAppendingPathComponent:@"cacert.pem"];
    [_state setRegistryValue:caInfo forKey:@"http.cainfo"];
    [_state setRegistryValue:runtimeDir forKey:@"http.capath"];

    // Service mode loads runtime/core.lua; execution mode loads a script or
    // evaluates LUAN_EXEC_CODE without starting the HTTP server.
    NSString *execScript = [[[NSProcessInfo processInfo] environment] objectForKey:@"LUAN_EXEC_SCRIPT"];
    NSString *execCode = [[[NSProcessInfo processInfo] environment] objectForKey:@"LUAN_EXEC_CODE"];
    BOOL execMode = (execScript.length > 0 || execCode.length > 0);
    NSString *entryPath = execScript.length > 0 ? execScript : [runtimeDir stringByAppendingPathComponent:@"core.lua"];
    if (execScript.length > 0 && ![entryPath hasPrefix:@"/"]) {
        entryPath = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:entryPath];
    }
    if (!execMode && ![fm fileExistsAtPath:entryPath]) {
        NSString *msg = [NSString stringWithFormat:@"!! 入口文件不存在: %@\n", entryPath];
        if (self.outputHandler) self.outputHandler(msg);
        else luan_emit(msg);
        decrRef(L);
        return;
    }

    // Load + resume the selected chunk and send errors to outputHandler/stderr.
    // Prefer outputHandler when set (avoid double print with luan_emit).
    void (^emit)(NSString *) = ^(NSString *msg) {
        if (self.outputHandler) self.outputHandler(msg);
        else luan_emit(msg);
    };

    lua_lock(L);
    lua_State *co = lua_newthread(L);
    int threadRef = luaL_ref(L, LUA_REGISTRYINDEX);

    int loadStatus = execCode.length > 0
        ? luaL_loadstring(co, [execCode UTF8String])
        : luaL_loadfile(co, [entryPath fileSystemRepresentation]);
    if (loadStatus != LUA_OK) {
        const char *err = lua_tostring(co, -1);
        NSString *msg = [NSString stringWithFormat:@"!! lua 加载失败 (%d): %s\n",
                         loadStatus, err ? err : "(no message)"];
        emit(msg);
    } else {
        lua_rawgeti(co, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
        lua_setupvalue(co, -2, 1);

        if (execMode) {
            lua_newtable(co);
            int argc = 0;
            const char *argcEnv = getenv("LUAN_ARGC");
            if (argcEnv) argc = atoi(argcEnv);
            const char *scriptName = execScript.length > 0 ? [entryPath UTF8String] : "-e";
            lua_pushstring(co, scriptName);
            lua_rawseti(co, -2, 0);
            for (int i = 0; i < argc; i++) {
                char key[64];
                snprintf(key, sizeof(key), "LUAN_ARG_%d", i);
                const char *value = getenv(key);
                if (value) {
                    lua_pushstring(co, value);
                    lua_rawseti(co, -2, i + 1);
                }
            }
            lua_setglobal(co, "arg");
        }
    }

    // Do not hold the outer setup lock across the v2 coroutine transition.
    lua_unlock(L);

    if (loadStatus == LUA_OK) {
        int status = fan_coro_resume(co, 0);
        // LUA_OK=0 finished; LUA_YIELD=1 suspended; >1 error.
        // If the entry coroutine yields before the loop starts, enter it here.
        if (status > LUA_YIELD) {
            const char *err = lua_tostring(co, -1);
            NSString *msg = [NSString stringWithFormat:@"!! lua 运行时错误 (%d): %s\n",
                             status, err ? err : "(no message)"];
            emit(msg);
        } else if (status == LUA_YIELD) {
            emit(@"!! lua entry yielded before fan.loop; entering fan_loop_run\n");
            fan_loop_run();
        } else {
            if (!execMode) {
                emit(@"!! lua entry returned LUA_OK without fan.loop (service would exit)\n");
            }
        }
    }

    lua_lock(L);
    luaL_unref(L, LUA_REGISTRYINDEX, threadRef);
    lua_unlock(L);

    // ---- cleanup ----
    // Clear every luafan2 module's cached Lua state before decrRef can close L.
    fan_clear_lua_states();
    _state = nil;
    decrRef(L);
    fan_loop_cleanup();
    LuanCloseLogFile();
}

- (void)stop {
    // Break the v2 event loop from the UI thread; cleanup continues on the
    // serialized Lua queue after fan_loop_run returns.
    fan_loop_break();
}

- (int)refCount {
    if (_state) {
        return [_state refCount];
    }
    return 0;
}

// MARK: - Metrics class methods

static int luan_process_metrics(lua_State *L) {
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)[LuaBridge currentLuaMemKB]);
    lua_setfield(L, -2, "lua_memory_kb");
    lua_pushinteger(L, (lua_Integer)[LuaBridge currentRSSBytes]);
    lua_setfield(L, -2, "rss_bytes");
    lua_pushnumber(L, [LuaBridge currentCPUPercent]);
    lua_setfield(L, -2, "cpu_percent");
    return 1;
}

+ (size_t)currentLuaMemKB {
    return atomic_load(&lua_mem_total) >> 10;
}

+ (size_t)currentRSSBytes {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) return 0;
    return (size_t)vmInfo.phys_footprint;
}

+ (double)currentCPUPercent {
    // 累计 CPU 时间(us) = 已退出线程 (task.user/system) + 当前线程 (thread_info.user/system).
    // 用相邻两次采样的 (cpu_time, wall_time) 差值算百分比. 第一次只填基线, 返回 0.
    static uint64_t prev_cpu_us = 0;
    static uint64_t prev_wall_us = 0;

    task_basic_info_data_t tinfo;
    mach_msg_type_number_t tcount = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO,
                  (task_info_t)&tinfo, &tcount) != KERN_SUCCESS) {
        return 0.0;
    }
    uint64_t cpu_us = (uint64_t)tinfo.user_time.seconds * 1000000 + tinfo.user_time.microseconds
                    + (uint64_t)tinfo.system_time.seconds * 1000000 + tinfo.system_time.microseconds;

    thread_array_t threads;
    mach_msg_type_number_t tnum = 0;
    if (task_threads(mach_task_self(), &threads, &tnum) == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < tnum; i++) {
            thread_basic_info_data_t thi;
            mach_msg_type_number_t thc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO,
                            (thread_info_t)&thi, &thc) != KERN_SUCCESS) continue;
            if (thi.flags & TH_FLAGS_IDLE) continue;
            cpu_us += (uint64_t)thi.user_time.seconds * 1000000 + thi.user_time.microseconds
                    + (uint64_t)thi.system_time.seconds * 1000000 + thi.system_time.microseconds;
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, tnum * sizeof(thread_t));
    }

    struct timeval now;
    gettimeofday(&now, NULL);
    uint64_t wall_us = (uint64_t)now.tv_sec * 1000000 + now.tv_usec;

    double pct = 0.0;
    if (prev_wall_us != 0 && wall_us > prev_wall_us && cpu_us >= prev_cpu_us) {
        double dcpu = (double)(cpu_us - prev_cpu_us);
        double dwall = (double)(wall_us - prev_wall_us);
        pct = (dcpu / dwall) * 100.0;
        double cap = (double)[[NSProcessInfo processInfo] activeProcessorCount] * 100.0;
        if (pct > cap) pct = cap;
        if (pct < 0) pct = 0;
    }
    prev_cpu_us = cpu_us;
    prev_wall_us = wall_us;
    return pct;
}

@end
