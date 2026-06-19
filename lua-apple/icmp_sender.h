//
//  icmp_sender.h — ICMP ping helpers for Lua
//  LuanMac / OpenLuan (MIT)
//

#ifndef icmp_sender_h
#define icmp_sender_h

#include "lua.h"

// Lua module entry point
int luaopen_icmp_sender(lua_State *L);

// Main functions
int lua_send_icmp_ping(lua_State *L);
int lua_create_icmp_socket(lua_State *L);

#endif /* icmp_sender_h */