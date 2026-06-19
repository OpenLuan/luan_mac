//
//  pal.h — Platform Abstraction Layer (iOS / Linux / Android / macOS host)
//  LuanMac / OpenLuan (MIT)
//
//  Platform-specific code is hidden behind these functions.
//

#ifndef pal_h
#define pal_h

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// TUN packet I/O
// ---------------------------------------------------------------------------

// Monotonically increasing counter of packets written to the TUN device.
// Used by the deadlock watchdog: if this counter advances between two checks
// the engine is still making progress and the watchdog skips that round.
extern _Atomic uint64_t pal_tun_write_count;

// Write a raw IP packet out through the TUN device.
// `protocol` is AF_INET (2) for IPv4.
void pal_tun_write_packet(const void *data, size_t len, int protocol);

// Callback invoked for each packet read from the TUN device.
// `data` points to a raw IP packet of `len` bytes.
// `protocol` is AF_INET for IPv4.
// Called on the engine's event queue — safe to access lwIP / Lua.
typedef void (*pal_tun_read_callback_t)(const void *data, size_t len, int protocol);

// Start the async packet read loop.  `cb` is called once per packet,
// dispatched onto the engine's libevent queue.
// On iOS this wraps NEPacketTunnelFlow readPacketsWithCompletionHandler:.
// On Linux this wraps read() on the tun fd + libevent.
void pal_tun_start_reading(pal_tun_read_callback_t cb);

// Stop reading (idempotent).
void pal_tun_stop_reading(void);

// ---------------------------------------------------------------------------
// System statistics
// ---------------------------------------------------------------------------

// Return the physical memory footprint (RSS) of this process in bytes.
// Returns (size_t)-1 on failure.
size_t pal_get_memory_usage(void);

// Return per-thread CPU usage as a Lua table pushed onto `L`.
// Returns the number of values pushed (1 table, or 0 on failure).
struct lua_State;
int pal_push_cpu_usage(struct lua_State *L);

// Return malloc zone statistics as a Lua table pushed onto `L`.
// Fields: size_in_use, size_allocated, max_size_in_use, blocks_in_use,
//         lua_mem_total, libevent_mem_total.
int pal_push_malloc_zone_statistics(struct lua_State *L);

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

// Show a local notification to the user.
// On OpenWrt this can be a no-op or syslog; on Android, JNI notification.
void pal_notify(const char *title, const char *message);

// ---------------------------------------------------------------------------
// Paths and device info
// ---------------------------------------------------------------------------

// Return the shared data directory (app group container on iOS,
// /var/lib/panpipe on OpenWrt, app data dir on Android).
// The returned string is valid for the lifetime of the process.
const char *pal_get_group_root(void);

// Return the runtime (merged Lua tree / core.lua) directory.
const char *pal_get_runtime_root(void);
// Legacy alias for pal_get_runtime_root.
const char *pal_get_service_root(void);

// Return the working/document directory for database, certs, etc.
const char *pal_get_document_root(void);

// Return a human-readable device name (e.g. "iPhone 15" / hostname).
const char *pal_get_device_name(void);

// Return an application bundle identifier / package name.
const char *pal_get_bundle_id(void);

// Return an issuer name string for MITM CA certificate.
const char *pal_get_issuer_name(void);

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// Platform-aware log output. `msg` is a UTF-8 string.
// On iOS this goes through os_log; on Linux, stderr/syslog.
void pal_log(const char *msg);

// ---------------------------------------------------------------------------
// Memory allocator for Lua state
// ---------------------------------------------------------------------------

// Return the allocation size of a pointer (e.g. malloc_size on macOS).
// Returns 0 if ptr is NULL.
size_t pal_alloc_size(void *ptr);

// Free a block previously allocated by pal_alloc_realloc.
void pal_alloc_free(void *ptr);

// Reallocate (or allocate) a block of memory.
// Equivalent to realloc() but using the platform's tracked zone allocator.
void *pal_alloc_realloc(void *ptr, size_t new_size);

// ---------------------------------------------------------------------------
// Lifecycle (called by the engine, implemented by each platform)
// ---------------------------------------------------------------------------

// Platform-specific initialization that must happen before the Lua engine
// starts.  Called once from TunnelService -start (iOS) or main() (Linux).
void pal_init(void);

// Set paths at runtime (called after pal_init, before pal_lua_bridge_register).
void pal_set_runtime_root(const char *path);
// Legacy alias for pal_set_runtime_root.
void pal_set_service_root(const char *path);
void pal_set_document_root(const char *path);

// ---------------------------------------------------------------------------
// Lua bridge (platform-independent, implemented in pal_lua_bridge.c)
// ---------------------------------------------------------------------------

// Register `bridge` and `notification` Lua globals backed by PAL.
void pal_lua_bridge_register(struct lua_State *L);

#ifdef __cplusplus
}
#endif

#endif /* pal_h */
