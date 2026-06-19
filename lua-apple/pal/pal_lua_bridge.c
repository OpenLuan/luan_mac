//
//  pal_lua_bridge.c — Lua bindings for PAL
//  LuanMac / OpenLuan (MIT)
//
//  Registers a Lua "bridge" userdata that delegates to pal.h functions.
//  Also registers a "notification" userdata with :show(title, message).
//  This file is platform-independent — it only calls pal_*() functions.
//

#include "pal.h"
#include "lua.h"
#include "lauxlib.h"
#include "llimits.h"

// ===========================================================================
// bridge userdata — methods callable from Lua as bridge:xxx()
// ===========================================================================

#define PAL_BRIDGE_MT "pal.bridge"

// bridge:getMemoryUsage() → integer (bytes)
static int bridge_getMemoryUsage(lua_State *L) {
    size_t mem = pal_get_memory_usage();
    lua_pushinteger(L, (lua_Integer)mem);
    return 1;
}

// bridge:setStatus(table) — store status table; on iOS this was just a
// property setter, the main app polls it via shared memory / IPC.
// We keep a registry reference so the table stays alive.
static int s_status_ref = LUA_NOREF;

static int bridge_setStatus(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_lock(L);
    if (s_status_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, s_status_ref);
    }
    lua_pushvalue(L, 2);
    s_status_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_unlock(L);
    return 0;
}

// bridge:setReadPacketHandler(func) — forward to PPTunnelPacket on iOS,
// or direct callback registration on other platforms.
// This is implemented as an extern so the platform code can hook in.
extern void pal_bridge_set_read_packet_handler(lua_State *L, int func_index);

static int bridge_setReadPacketHandler(lua_State *L) {
    pal_bridge_set_read_packet_handler(L, 2);
    return 0;
}

// bridge:setDNSPort(port) — forward to evdns reconfiguration.
// This is implemented as an extern so the platform code can hook in.
extern void pal_bridge_set_dns_port(int port);

static int bridge_setDNSPort(lua_State *L) {
    int port = (int)luaL_checkinteger(L, 2);
    pal_bridge_set_dns_port(port);
    return 0;
}

// bridge:getLuaMemoryUsage() → integer
extern size_t lua_mem_total;

static int bridge_getLuaMemoryUsage(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)lua_mem_total);
    return 1;
}

static const luaL_Reg bridge_methods[] = {
    {"getMemoryUsage",       bridge_getMemoryUsage},
    {"setStatus",            bridge_setStatus},
    {"setReadPacketHandler", bridge_setReadPacketHandler},
    {"setDNSPort",           bridge_setDNSPort},
    {"getLuaMemoryUsage",    bridge_getLuaMemoryUsage},
    {NULL, NULL}
};

// ===========================================================================
// notification userdata — methods callable from Lua as notification:xxx()
// ===========================================================================

#define PAL_NOTIFICATION_MT "pal.notification"

// notification:show(title, message)
static int notification_show(lua_State *L) {
    size_t title_len, msg_len;
    const char *title = luaL_checklstring(L, 2, &title_len);
    const char *message = luaL_checklstring(L, 3, &msg_len);
    pal_notify(title, message);
    return 0;
}

static const luaL_Reg notification_methods[] = {
    {"show", notification_show},
    {NULL, NULL}
};

// ===========================================================================
// Registration
// ===========================================================================

// Create and push a userdata with the given metatable.
static void push_singleton(lua_State *L, const char *mt_name,
                           const luaL_Reg *methods) {
    // Create a small dummy userdata (1 byte — we don't need storage)
    lua_newuserdata(L, 1);

    // Create metatable
    luaL_newmetatable(L, mt_name);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");  // mt.__index = mt
    luaL_setfuncs(L, methods, 0);
    lua_setmetatable(L, -2);
}

// Called from TunnelService (or platform main) to register globals.
void pal_lua_bridge_register(lua_State *L) {
    // _G.bridge
    push_singleton(L, PAL_BRIDGE_MT, bridge_methods);
    lua_setglobal(L, "bridge");

    // _G.notification
    push_singleton(L, PAL_NOTIFICATION_MT, notification_methods);
    lua_setglobal(L, "notification");

    // String globals from PAL
    // Note: groupRoot, runtimeRoot, documentRoot

    lua_pushstring(L, pal_get_bundle_id());
    lua_setglobal(L, "bundleIdentifier");

    lua_pushstring(L, pal_get_device_name());
    lua_setglobal(L, "deviceName");

    lua_pushstring(L, pal_get_issuer_name());
    lua_setglobal(L, "issuerName");
}
