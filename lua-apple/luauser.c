#include <stdio.h>
#include "lua.h"
#include "luauser.h"
#include "lauxlib.h"
#include "lstate.h"

#include <memory.h>
#include <stdlib.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#include <dispatch/dispatch.h>
#endif
#include <sys/time.h>
#include <stdatomic.h>
#include <unistd.h>

#include "pal.h"

//#define P_DEBUG

#ifdef __ANDROID__

#include <android/log.h>
#define LOG_TAG "lua.print"
#undef LOG
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG , LOG_TAG,__VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR , LOG_TAG,__VA_ARGS__)

#else

#define LOGD(...) fprintf(stdout, __VA_ARGS__)
#define LOGE(...) fprintf(stderr, __VA_ARGS__)

#endif

#ifndef GLOBAL_LOCK
#define STATEDATA_TOLOCK(L) (*((StateData **)lua_getextraspace(L))->lock
#else
pthread_mutex_t lock;
int lockInited = 0;
#define STATEDATA_TOLOCK(L) lock
#endif

// Thread-local lock depth counter.
// Only the outermost lock/unlock pair operates the real mutex;
// inner (nested) calls just adjust the counter.  This makes the lock
// resilient to Lua longjmp skipping inner lua_unlock calls:
// the outermost unlock still releases the mutex correctly.
static _Thread_local int lua_lock_depth = 0;

// Runtime lock switch. The global Lua mutex is only worth taking when more
// than one thread can touch the shared lua_State — i.e. when luafan worker
// threads are running. With no workers everything runs on a single thread and
// the mutex is pure overhead, so we keep it disabled (lock/unlock become a
// relaxed atomic load + branch, effectively free).
//
// event_mgr_workers_init() calls LuaLockEnable() BEFORE spawning any worker
// thread, so the switch is observed as enabled by every thread that could ever
// contend. It is a one-way latch (never flipped back to 0 within a run), which
// avoids any enable/disable race: once a worker exists, locking stays on.
static atomic_int g_lua_locking_enabled = 0;

// Called by luafan (event_mgr_workers_init) before the first worker thread is
// created. Safe to call multiple times.
void LuaLockEnable(void) {
    atomic_store_explicit(&g_lua_locking_enabled, 1, memory_order_release);
}

static inline int lua_locking_on(void) {
    return atomic_load_explicit(&g_lua_locking_enabled, memory_order_acquire);
}

lua_State* GetMainState(lua_State *L){
    if (L) {
        return L->l_G->mainthread;
    } else {
        return NULL;
    }
}

void LockMainState(lua_State *L){
    if (L && lua_locking_on()) {
        if (lua_lock_depth == 0) {
            pthread_mutex_lock(&STATEDATA_TOLOCK(L));
        }
        lua_lock_depth++;
    }
}

void UnLockMainState(lua_State *L){
    if (L && lua_locking_on()) {
        if (lua_lock_depth <= 0) {
            // Defensive: unbalanced unlock, should not happen.
            // Do not touch the mutex — it is not held by this thread.
            return;
        }
        lua_lock_depth--;
        if (lua_lock_depth == 0) {
            pthread_mutex_unlock(&STATEDATA_TOLOCK(L));
        }
    }
}

// Lock/unlock the global Lua mutex without requiring a lua_State pointer.
// Uses the same lua_lock_depth to allow nesting with LockMainState.
void LuaGlobalLock(void) {
    if (lockInited && lua_locking_on()) {
        if (lua_lock_depth == 0) {
            pthread_mutex_lock(&lock);
        }
        lua_lock_depth++;
    }
}

void LuaGlobalUnlock(void) {
    if (lockInited && lua_locking_on()) {
        if (lua_lock_depth <= 0) {
            return;
        }
        lua_lock_depth--;
        if (lua_lock_depth == 0) {
            pthread_mutex_unlock(&lock);
        }
    }
}

// The main thread enters fan.loop() from inside a resume that holds the global
// Lua lock (lua_lock_depth > 0). event_base_loop() then blocks forever, so the
// lock is never released and worker-thread callbacks that need Lua deadlock in
// LockMainState. Suspend releases the lock fully (records depth, unlocks the
// mutex, zeroes the thread-local depth) so worker threads can acquire it while
// the main thread is parked in the loop dispatching its own callbacks via the
// normal lock/unlock pairs. Resume restores the recorded depth and re-acquires
// the mutex after the loop exits, so the enclosing resume's trailing unlock
// stays balanced. Returns the suspended depth (0 means nothing was held).
int LuaLockSuspendForLoop(void) {
    int depth = lua_lock_depth;
    if (lockInited && depth > 0) {
        lua_lock_depth = 0;
        pthread_mutex_unlock(&lock);
    }
    return depth;
}

void LuaLockResumeAfterLoop(int depth) {
    if (lockInited && depth > 0) {
        pthread_mutex_lock(&lock);
        lua_lock_depth = depth;
    }
}

void LuaLockInitial(lua_State * L){
    StateData **sd = (StateData **)lua_getextraspace(L);
    *sd = malloc(sizeof(StateData));
    (*sd)->count = 0;
    (*sd)->thread_count = 0;

#ifdef GLOBAL_LOCK
    if (!lockInited) {
#endif
        pthread_mutexattr_t a;
        pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_NORMAL);
        pthread_mutex_init(&STATEDATA_TOLOCK(L), &a);
        
        lockInited = 1;
#ifdef GLOBAL_LOCK
    }
#endif

#ifdef P_DEBUG
    LOGD("initialState 0x%08lX\n", (long)L);
#endif
}

void LuaLockInitialThread(lua_State * L, lua_State * co){
    StateData *sd = *((StateData **)lua_getextraspace(L));
    sd->thread_count = sd->thread_count + 1;

#ifdef P_DEBUG
    unsigned int thread_count = sd->thread_count;
    LOGD("initialThread 0x%08lX thread_count: %d -> %d\n", (long)co, thread_count - 1, thread_count);
#endif
}

void LuaLockFinalState(lua_State * L){
    // lua_close() holds the lock; force-release regardless of depth.
    if (lua_lock_depth > 0) {
        lua_lock_depth = 0;
        pthread_mutex_unlock(&STATEDATA_TOLOCK(L));
    }
#ifndef GLOBAL_LOCK
    pthread_mutex_destroy(&STATEDATA_TOLOCK(L));
#endif
    StateData **sd = (StateData **)lua_getextraspace(L);
    free(*sd);
}

void LuaLockFinalThread(lua_State * L, lua_State * co){
    StateData *sd = *((StateData **)lua_getextraspace(L));
    sd->thread_count = sd->thread_count - 1;
#ifdef P_DEBUG
    unsigned int thread_count = sd->thread_count;
    LOGD("finalThread 0x%08lX thread_count: %d -> %d\n", (long)co, thread_count + 1, thread_count);
#endif
}

void incrRef(lua_State *L){
    StateData *sd = *((StateData **)lua_getextraspace(L));
    lua_lock(L);

#ifdef P_DEBUG
        lua_getfield(L, LUA_REGISTRYINDEX, "dataPath");
        if (lua_type(L, -1) == LUA_TSTRING) {
            LOGD("0x%08lX(ROOT)\t%s incrRefRoot %d -> %d\n", (long)L, lua_tostring(L, -1), sd->count, sd->count + 1);
        } else {
            LOGD("0x%08lX(ROOT)\t incrRefRoot %d -> %d\n", (long)L, sd->count, sd->count + 1);
        }
        lua_pop(L, 1);
#endif
    
    sd->count = sd->count + 1;
    lua_unlock(L);
}

void decrRef(lua_State *L){
    StateData *sd = *((StateData **)lua_getextraspace(L));
    lua_lock(L);

#ifdef P_DEBUG
        lua_getfield(L, LUA_REGISTRYINDEX, "dataPath");
        if (lua_type(L, -1) == LUA_TSTRING) {
            LOGD("0x%08lX(ROOT)\t%s decrRefRoot %d -> %d\n", (long)L, lua_tostring(L, -1), sd->count, sd->count - 1);
        } else {
            LOGD("0x%08lX(ROOT)\t decrRefRoot %d -> %d\n", (long)L, sd->count, sd->count - 1);
        }
        lua_pop(L, 1);
#endif
    
    sd->count = sd->count - 1;
    
    lua_unlock(L);
    
//    if (STATEDATA_TO_COUNT(L) == 1) {
//        lua_gc(ROOT, LUA_GCCOLLECT, 0);
//    }

    if (sd->count <= 0) {
#ifdef P_DEBUG
        if (sd->thread_count > 0) {
            LOGD("dealloc on thread_count = %d\n", sd->thread_count);
        }
#endif
//        malloc_zone_t *zone = (malloc_zone_t *) G(L)->ud;
        lua_close(L);
//        malloc_destroy_zone(zone);
#ifdef P_DEBUG
        LOGD("dealloc state\n");
#endif
    }
}

LUALIB_API int luaL_typerror (lua_State *L, int narg, const char *tname) {
  const char *msg = lua_pushfstring(L, "%s expected, got %s",
                                    tname, luaL_typename(L, narg));
  return luaL_argerror(L, narg, msg);
}

int LuaLockDepthGet(void) { return lua_lock_depth; }
void LuaLockDepthSet(int depth) { lua_lock_depth = depth; }

int LuaRefCount(lua_State *L) {
    if (!L) return 0;
    StateData *sd = *((StateData **)lua_getextraspace(L));
    return sd ? sd->count : 0;
}

// MARK: - Deadlock Watchdog

#ifdef __APPLE__
static dispatch_source_t watchdog_timer = NULL;
static dispatch_queue_t watchdog_queue = NULL;

// Snapshot of pal_tun_write_count from the previous watchdog check.
static uint64_t watchdog_last_write_count = 0;

// Watchdog check interval (seconds)
#define LUA_LOCK_WATCHDOG_INTERVAL 1
// Lock acquisition: poll interval (microseconds) and max attempts.
// Total timeout = interval × attempts = 500ms × 20 = 10s.
#define LUA_LOCK_TRYLOCK_INTERVAL_US  500000  // 0.5s
#define LUA_LOCK_TRYLOCK_MAX_ATTEMPTS 20

// Memory thresholds for Network Extension (bytes).
// NE limit varies by device (typically 50–80 MB).  Use conservative values.
#define MEMORY_WARNING_THRESHOLD  (40 * 1024 * 1024)   // 40 MB — start logging
#define MEMORY_CRITICAL_THRESHOLD (55 * 1024 * 1024)    // 55 MB — log critical

void LuaLockWatchdogStart(void) {
    if (watchdog_timer) return;  // already running

    watchdog_queue = dispatch_queue_create("lua_lock_watchdog", DISPATCH_QUEUE_SERIAL);
    watchdog_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchdog_queue);

    dispatch_source_set_timer(watchdog_timer,
        dispatch_time(DISPATCH_TIME_NOW, LUA_LOCK_WATCHDOG_INTERVAL * NSEC_PER_SEC),
        LUA_LOCK_WATCHDOG_INTERVAL * NSEC_PER_SEC,
        1 * NSEC_PER_SEC);  // 1s leeway

    watchdog_last_write_count = atomic_load_explicit(&pal_tun_write_count,
                                                     memory_order_relaxed);

    dispatch_source_set_event_handler(watchdog_timer, ^{
        if (!lockInited) return;

        // --- Memory pressure check (no lock needed) ---
        size_t mem = pal_get_memory_usage();
        if (mem != (size_t)-1 && mem >= MEMORY_WARNING_THRESHOLD) {
            char buf[128];
            if (mem >= MEMORY_CRITICAL_THRESHOLD) {
                snprintf(buf, sizeof(buf),
                         "[WATCHDOG] CRITICAL memory: %zu bytes (%.1f MB). "
                         "NE may be killed by the system soon!",
                         mem, mem / (1024.0 * 1024.0));
            } else {
                snprintf(buf, sizeof(buf),
                         "[WATCHDOG] High memory: %zu bytes (%.1f MB)",
                         mem, mem / (1024.0 * 1024.0));
            }
            pal_log(buf);

            // Throttle the engine: hold the Lua lock briefly so the engine
            // pauses allocations and gives the system a chance to reclaim memory.
            if (pthread_mutex_trylock(&lock) == 0) {
                usleep(100000);  // 0.1s
                pthread_mutex_unlock(&lock);
            }
        }

        // --- Deadlock check ---

        // If packets have been written to TUN since the last check the engine
        // is still making progress — skip this round.
        uint64_t current_write_count = atomic_load_explicit(&pal_tun_write_count,
                                                            memory_order_relaxed);
        if (current_write_count != watchdog_last_write_count) {
            watchdog_last_write_count = current_write_count;
            return;
        }

        // pthread_mutex_timedlock is not available on Apple platforms,
        // so poll with trylock + usleep to approximate a timed lock.
        int acquired = 0;
        int attempts = 0;
        while (attempts < LUA_LOCK_TRYLOCK_MAX_ATTEMPTS) {
            int ret = pthread_mutex_trylock(&lock);
            if (ret == 0) {
                acquired = 1;
                pthread_mutex_unlock(&lock);
                break;
            }
            usleep(LUA_LOCK_TRYLOCK_INTERVAL_US);
            attempts++;

            // Re-check packet activity during the polling window.
            uint64_t recheck = atomic_load_explicit(&pal_tun_write_count,
                                                    memory_order_relaxed);
            if (recheck != watchdog_last_write_count) {
                watchdog_last_write_count = recheck;
                return;
            }
        }

        if (!acquired) {
            char buf[128];
            snprintf(buf, sizeof(buf),
                     "[WATCHDOG] lua_lock deadlock detected! "
                     "Could not acquire lock after %d attempts. Forcing exit.",
                     LUA_LOCK_TRYLOCK_MAX_ATTEMPTS);
            pal_log(buf);
            exit(1);
        }
    });

    dispatch_resume(watchdog_timer);
}

void LuaLockWatchdogStop(void) {
    if (watchdog_timer) {
        dispatch_source_cancel(watchdog_timer);
        watchdog_timer = NULL;
    }
    watchdog_queue = NULL;
}
#else
// Non-Apple: watchdog not supported (requires GCD)
void LuaLockWatchdogStart(void) {}
void LuaLockWatchdogStop(void) {}
#endif
