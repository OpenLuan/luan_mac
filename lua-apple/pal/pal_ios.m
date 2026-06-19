//
//  pal_ios.m — iOS Platform Abstraction Layer
//  LuanMac / OpenLuan (MIT)
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <os/log.h>

#ifndef TUNNEL_IN_MAIN_TARGET
#import <NetworkExtension/NetworkExtension.h>
#import <UserNotifications/UserNotifications.h>
#endif

#include "pal.h"
#include "lua.h"
#include "lauxlib.h"
#include "llimits.h"
#ifndef PAL_NO_TUNNEL
#import "PPTunnelPacket.h"
#endif
#include <event2/dns.h>
#include "event_mgr.h"

// ---------------------------------------------------------------------------
// Externs from existing code
// ---------------------------------------------------------------------------

extern _Atomic size_t lua_mem_total;
extern _Atomic size_t libevent_mem_total;

_Atomic uint64_t pal_tun_write_count = 0;

#ifndef TUNNEL_IN_MAIN_TARGET
// Private storage — set by PacketTunnelProvider via pal_ios_set_packet_flow().
static NEPacketTunnelFlow *s_packetFlow;

void pal_ios_set_packet_flow(NEPacketTunnelFlow *flow) {
    s_packetFlow = flow;
}
#endif

// Static storage for path strings (populated once in pal_init)
static char s_group_root[1024];
static char s_runtime_root[1024];
static char s_document_root[1024];
static char s_device_name[256];
static char s_bundle_id[256];
static char s_issuer_name[512];

// ---------------------------------------------------------------------------
// TUN packet I/O
// ---------------------------------------------------------------------------

void pal_tun_write_packet(const void *data, size_t len, int protocol) {
#ifndef TUNNEL_IN_MAIN_TARGET
    if (!s_packetFlow || !data || len == 0) {
        return;
    }
    atomic_fetch_add_explicit(&pal_tun_write_count, 1, memory_order_relaxed);
    @autoreleasepool {
        NSData *pkt = [NSData dataWithBytes:data length:len];
        [s_packetFlow writePackets:@[pkt] withProtocols:@[@(protocol)]];
    }
#endif
}

#ifndef TUNNEL_IN_MAIN_TARGET

// --- TUN read loop state ---

static pal_tun_read_callback_t s_read_callback = NULL;
static BOOL s_reading_active = NO;

// Holds a batch of packets dispatched as a single event onto the engine queue.
// Back-pressure: the next read is initiated only after the batch is processed.
struct pal_read_batch_arg {
    void **packets;       // array of packet data pointers
    size_t *lengths;      // array of packet lengths
    int *protocols;       // array of protocol values
    NSUInteger count;
    pal_tun_read_callback_t cb;
    struct event *ev;
};

// Forward declaration.
static void pal_tun_read_loop(void);

// Libevent callback — runs on the engine queue.
// Processes the entire batch, then continues reading (back-pressure).
static void pal_read_batch_cb(int fd, short kind, void *userp) {
    struct pal_read_batch_arg *arg = (struct pal_read_batch_arg *)userp;
    if (arg->cb) {
        for (NSUInteger i = 0; i < arg->count; i++) {
            if (arg->packets[i]) {
                arg->cb(arg->packets[i], arg->lengths[i], arg->protocols[i]);
            }
        }
    }
    // Free all packet data
    for (NSUInteger i = 0; i < arg->count; i++) {
        free(arg->packets[i]);
    }
    free(arg->packets);
    free(arg->lengths);
    free(arg->protocols);
    event_free(arg->ev);
    free(arg);

    // Continue reading after processing (back-pressure).
    pal_tun_read_loop();
}

static void pal_tun_read_loop(void) {
    if (!s_reading_active || !s_packetFlow || !s_read_callback) {
        return;
    }

    pal_tun_read_callback_t cb = s_read_callback;

    [s_packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,
                                                   NSArray<NSNumber *> *protocols) {
        if (!packets || !protocols) {
            // Read failure — retry after 1 second.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                pal_tun_read_loop();
            });
            return;
        }

        // Count valid packets
        NSUInteger validCount = 0;
        for (NSUInteger i = 0; i < packets.count; i++) {
            if (packets[i].length > 0) validCount++;
        }
        if (validCount == 0) {
            pal_tun_read_loop();
            return;
        }

        // Build batch
        struct pal_read_batch_arg *arg = malloc(sizeof(struct pal_read_batch_arg));
        if (!arg) { pal_tun_read_loop(); return; }

        arg->packets = malloc(sizeof(void *) * validCount);
        arg->lengths = malloc(sizeof(size_t) * validCount);
        arg->protocols = malloc(sizeof(int) * validCount);
        if (!arg->packets || !arg->lengths || !arg->protocols) {
            free(arg->packets);
            free(arg->lengths);
            free(arg->protocols);
            free(arg);
            pal_tun_read_loop();
            return;
        }

        NSUInteger idx = 0;
        for (NSUInteger i = 0; i < packets.count; i++) {
            NSData *pkt = packets[i];
            if (pkt.length > 0) {
                arg->packets[idx] = malloc(pkt.length);
                if (arg->packets[idx]) {
                    memcpy(arg->packets[idx], pkt.bytes, pkt.length);
                    arg->lengths[idx] = pkt.length;
                    arg->protocols[idx] = protocols[i].intValue;
                    idx++;
                }
            }
        }
        arg->count = idx;
        arg->cb = cb;
        arg->ev = evuser_new(event_mgr_base_current(), pal_read_batch_cb, arg);
        if (!arg->ev) {
            for (NSUInteger i = 0; i < idx; i++) free(arg->packets[i]);
            free(arg->packets);
            free(arg->lengths);
            free(arg->protocols);
            free(arg);
            pal_tun_read_loop();
            return;
        }
        struct timeval t = {0, 1};
        event_add(arg->ev, &t);
    }];
}

void pal_tun_start_reading(pal_tun_read_callback_t cb) {
    if (!cb) return;
    s_read_callback = cb;
    s_reading_active = YES;
    pal_tun_read_loop();
}

void pal_tun_stop_reading(void) {
    s_reading_active = NO;
    s_read_callback = NULL;
}

#else
// TUNNEL_IN_MAIN_TARGET stubs
void pal_tun_start_reading(pal_tun_read_callback_t cb) { (void)cb; }
void pal_tun_stop_reading(void) {}
#endif

// ---------------------------------------------------------------------------
// System statistics
// ---------------------------------------------------------------------------

size_t pal_get_memory_usage(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                (task_info_t)&vmInfo, &count);
    if (kr == KERN_SUCCESS) {
        return (size_t)vmInfo.phys_footprint;
    }
    return (size_t)-1;
}

int pal_push_cpu_usage(lua_State *L) {
    kern_return_t kr;
    task_info_data_t tinfo;
    mach_msg_type_number_t task_info_count = TASK_INFO_MAX;

    kr = task_info(mach_task_self(), TASK_BASIC_INFO,
                   (task_info_t)tinfo, &task_info_count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }

    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;

    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }

    lua_newtable(L);

    for (int j = 0; j < (int)thread_count; j++) {
        thread_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;

        kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                         (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            vm_deallocate(mach_task_self(), (vm_offset_t)thread_list,
                          thread_count * sizeof(thread_t));
            return 0;
        }

        lua_newtable(L);
        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;

        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            lua_newtable(L);
            lua_pushnumber(L, basic_info_th->user_time.seconds);
            lua_setfield(L, -2, "seconds");
            lua_pushnumber(L, basic_info_th->user_time.microseconds);
            lua_setfield(L, -2, "microseconds");
            lua_setfield(L, -2, "user_time");

            lua_newtable(L);
            lua_pushnumber(L, basic_info_th->system_time.seconds);
            lua_setfield(L, -2, "seconds");
            lua_pushnumber(L, basic_info_th->system_time.microseconds);
            lua_setfield(L, -2, "microseconds");
            lua_setfield(L, -2, "system_time");

            lua_pushnumber(L, basic_info_th->cpu_usage /
                           (float)TH_USAGE_SCALE * 100.0);
            lua_setfield(L, -2, "cpu_usage");
        }

        lua_seti(L, -2, j + 1);
    }

    vm_deallocate(mach_task_self(), (vm_offset_t)thread_list,
                  thread_count * sizeof(thread_t));
    return 1;
}

int pal_push_malloc_zone_statistics(lua_State *L) {
    malloc_statistics_t stat = {0};
    malloc_zone_statistics(NULL, &stat);

    lua_newtable(L);
    lua_pushinteger(L, stat.size_in_use);
    lua_setfield(L, -2, "size_in_use");
    lua_pushinteger(L, stat.size_allocated);
    lua_setfield(L, -2, "size_allocated");
    lua_pushinteger(L, stat.max_size_in_use);
    lua_setfield(L, -2, "max_size_in_use");
    lua_pushinteger(L, stat.blocks_in_use);
    lua_setfield(L, -2, "blocks_in_use");
    lua_pushinteger(L, lua_mem_total);
    lua_setfield(L, -2, "lua_mem_total");
    lua_pushinteger(L, libevent_mem_total);
    lua_setfield(L, -2, "libevent_mem_total");

    return 1;
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

void pal_notify(const char *title, const char *message) {
#ifndef TUNNEL_IN_MAIN_TARGET
    if (@available(iOS 10.0, *)) {
        @autoreleasepool {
            NSString *nsTitle = title ? [NSString stringWithUTF8String:title] : @"";
            NSString *nsMessage = message ? [NSString stringWithUTF8String:message] : @"";

            nsTitle = [NSString localizedUserNotificationStringForKey:nsTitle
                                                           arguments:nil];
            nsMessage = [NSString localizedUserNotificationStringForKey:nsMessage
                                                             arguments:nil];

            UNMutableNotificationContent *content =
                [[UNMutableNotificationContent alloc] init];
            content.title = nsTitle;
            content.body = nsMessage;
            content.sound = [UNNotificationSound defaultSound];

            UNNotificationRequest *request = [UNNotificationRequest
                requestWithIdentifier:[[NSUUID UUID] UUIDString]
                              content:content
                              trigger:nil];

            UNUserNotificationCenter *center =
                [UNUserNotificationCenter currentNotificationCenter];
            [center addNotificationRequest:request
                     withCompletionHandler:^(NSError *_Nullable error) {
                if (error) {
                    NSLog(@"pal_notify error: %@", error);
                }
            }];
        }
    }
#endif
}

// ---------------------------------------------------------------------------
// Paths and device info
// ---------------------------------------------------------------------------

const char *pal_get_group_root(void)   { return s_group_root; }
const char *pal_get_runtime_root(void) { return s_runtime_root; }
// Legacy alias for pal_get_runtime_root.
const char *pal_get_service_root(void) { return s_runtime_root; }
const char *pal_get_document_root(void){ return s_document_root; }
const char *pal_get_device_name(void)  { return s_device_name; }
const char *pal_get_bundle_id(void)    { return s_bundle_id; }
const char *pal_get_issuer_name(void)  { return s_issuer_name; }

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void pal_log(const char *msg) {
    if (msg) {
        os_log(OS_LOG_DEFAULT, "[Luan] %{public}s", msg);
    }
}

// ---------------------------------------------------------------------------
// Memory allocator for Lua state
// ---------------------------------------------------------------------------

size_t pal_alloc_size(void *ptr) {
    return malloc_size(ptr);
}

void pal_alloc_free(void *ptr) {
    malloc_zone_free(malloc_default_zone(), ptr);
}

void *pal_alloc_realloc(void *ptr, size_t new_size) {
    return malloc_zone_realloc(malloc_default_zone(), ptr, new_size);
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

void pal_init(void) {
    @autoreleasepool {
        // Group root
#ifdef GROUP_ID
        NSURL *groupURL = [[NSFileManager defaultManager]
            containerURLForSecurityApplicationGroupIdentifier:GROUP_ID];
        if (groupURL) {
            const char *p = [[groupURL path] stringByAppendingString:@"/"]
                                .fileSystemRepresentation;
            if (p) strlcpy(s_group_root, p, sizeof(s_group_root));
        }
#endif

        // Bundle identifier
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        strlcpy(s_bundle_id, bid.UTF8String, sizeof(s_bundle_id));

        // Device name
#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
        NSString *name = [UIDevice currentDevice].name ?: @"";
#else
        NSString *name = [[NSProcessInfo processInfo] hostName] ?: @"";
#endif
        strlcpy(s_device_name, name.UTF8String, sizeof(s_device_name));

        // Issuer name
        int32_t ts = (int32_t)[NSDate timeIntervalSinceReferenceDate];
        NSData *tsData = [NSData dataWithBytes:&ts length:sizeof(ts)];
        // Import the hex category for consistency, but use a simple hex conversion
        NSMutableString *hex = [NSMutableString stringWithCapacity:tsData.length * 2];
        const uint8_t *bytes = tsData.bytes;
        for (NSUInteger i = 0; i < tsData.length; i++) {
            [hex appendFormat:@"%02x", bytes[i]];
        }
        NSString *issuer = [NSString stringWithFormat:@"Luan: '%@' - %@",
                            name, hex];
        strlcpy(s_issuer_name, issuer.UTF8String, sizeof(s_issuer_name));

        // Service root and document root are set later by TunnelService -start
        // because they depend on runtime path resolution.
    }
}

// ---------------------------------------------------------------------------
// Helpers called from TunnelService -start to set paths at runtime
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Bridge callbacks (called from pal_lua_bridge.c via extern)
// ---------------------------------------------------------------------------

extern lua_State *utlua_mainthread(lua_State *L);

void pal_bridge_set_read_packet_handler(lua_State *L, int func_index) {
#ifndef PAL_NO_TUNNEL
    @autoreleasepool {
        LuaFunction *func = nil;
        if (lua_isfunction(L, func_index)) {
            lua_lock(L);
            lua_pushvalue(L, func_index);
            int ref = luaL_ref(L, LUA_REGISTRYINDEX);
            lua_unlock(L);
            func = [[LuaFunction alloc] initWithRef:ref
                                          withState:utlua_mainthread(L)];
        }
        [PPTunnelPacket.shared setReadPacketHandler:func];
    }
#else
    (void)L; (void)func_index;
#endif
}

void pal_bridge_set_dns_port(int port) {
    extern BOOL pp_ipv6;
    if (pp_ipv6 || port < 1 || port > 65535) {
        return;
    }

    char dns_server[32];
    snprintf(dns_server, sizeof(dns_server), "127.0.0.1:%d", port);

    struct evdns_base *dns_base = event_mgr_dnsbase();
    if (!dns_base) return;

    evdns_base_clear_nameservers_and_suspend(dns_base);
    evdns_base_nameserver_ip_add(dns_base, dns_server);
    evdns_base_resume(dns_base);

    for (int i = 0; i < event_mgr_worker_count(); i++) {
        struct evdns_base *worker_dns = event_mgr_worker_dnsbase(i);
        if (worker_dns) {
            evdns_base_clear_nameservers_and_suspend(worker_dns);
            evdns_base_nameserver_ip_add(worker_dns, dns_server);
            evdns_base_resume(worker_dns);
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers called from TunnelService -start to set paths at runtime
// ---------------------------------------------------------------------------

void pal_set_runtime_root(const char *path) {
    if (path) strlcpy(s_runtime_root, path, sizeof(s_runtime_root));
}

// Legacy alias for pal_set_runtime_root.
void pal_set_service_root(const char *path) {
    pal_set_runtime_root(path);
}

void pal_set_document_root(const char *path) {
    if (path) strlcpy(s_document_root, path, sizeof(s_document_root));
}
