//
//  caplua.c — Lua state bootstrap / package.preload registration
//  LuanMac / OpenLuan (MIT)
//

#include <stdio.h>
#include "utlua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdlib.h>
#include <pthread.h>
#include <errno.h>
#include "lfs.h"
#include <ctype.h>
#include <math.h>
#include <sys/time.h>
#include "event_mgr.h"

#include "pal.h"

#include "uthash.h"
#include "icmp_sender.h"
#include "wildcard_matcher.h"
#include "evdns.h"

#ifdef __ANDROID__

#include <jni.h>
extern JavaVM *cachedJVM;
extern void incrRef(lua_State *L);
extern void decrRef(lua_State *L);

#endif

#if !defined(__ANDROID__) || __ANDROID_API__ >= 28
LUA_API int luaopen_iconv(lua_State *L);
#endif
LUA_API int luaopen_json(lua_State *L);
LUA_API int luaopen_zlib(lua_State *L);

static ptrdiff_t posrelat (ptrdiff_t pos, size_t len) {
    /* relative string position: negative means back from end */
    if (pos < 0) pos += (ptrdiff_t)len + 1;
    return (pos >= 0) ? pos : 0;
}

static int chsize(unsigned char c){
    if (c >= 0xF0) {
        return 4;
    }else if (c >= 0xE0) {
        return 3;
    }else if (c >= 0xC0) {
        return 2;
    }else {
        return 1;
    }
}

static int str_ptime (lua_State *L) {
    size_t l1;
    size_t l2;
    struct tm created;
    time_t time;
    
    const char *s1 = luaL_checklstring(L, 1, &l1);
    const char *s2 = luaL_checklstring(L, 2, &l2);
    if (strptime(s1, s2, &created) == NULL) {
        luaL_error(L, "unable to parse date format %s %s", s1, s2);
    }
    time = mktime(&created);
    
    lua_pushinteger(L, time);
    
    return 1;
}

static int str_trim(lua_State *L){
    const char *front;
    const char *end;
    size_t      size;
    
    front = luaL_checklstring(L,1,&size);
    end   = &front[size - 1];
    
    for ( ; size && isspace(*front) ; size-- , front++);
    for ( ; size && isspace(*end) ; size-- , end--);
    
    lua_pushlstring(L,front,(size_t)(end - front) + 1);
    return 1;
}

static const char *lmemfind (const char *s1, size_t l1,
                             const char *s2, size_t l2) {
    if (l2 == 0) return s1;  /* empty strings are everywhere */
    else if (l2 > l1) return NULL;  /* avoids a negative `l1' */
    else {
        const char *init;  /* to search for a `*s2' inside `s1' */
        l2--;  /* 1st char will be checked by `memchr' */
        l1 = l1-l2;  /* `s2' cannot be found after that */
        while (l1 > 0 && (init = (const char *)memchr(s1, *s2, l1)) != NULL) {
            init++;   /* 1st char is already checked */
            if (memcmp(init, s2+1, l2) == 0)
                return init-1;
            else {  /* correct `l1' and `s1' to try again */
                l1 -= init-s1;
                s1 = init;
            }
        }
        return NULL;  /* not found */
    }
}

/* http://lua-users.org/wiki/StringReplace */
static int str_replace(lua_State *L) {
    size_t l1, l2, l3;
    const char *src = luaL_checklstring(L, 1, &l1);
    const char *p = luaL_checklstring(L, 2, &l2);
    const char *p2 = luaL_checklstring(L, 3, &l3);
    const char *s2;
    int n = 0;
    size_t init = 0;

    luaL_Buffer b;
    luaL_buffinit(L, &b);

    while (1) {
        s2 = lmemfind(src+init, l1-init, p, l2);
        if (s2) {
            luaL_addlstring(&b, src+init, s2-(src+init));
            luaL_addlstring(&b, p2, l3);
            init = init + (s2-(src+init)) + l2;
            n++;
        } else {
            luaL_addlstring(&b, src+init, l1-init);
            break;
        }
    }

    luaL_pushresult(&b);
    lua_pushinteger(L, n);  /* number of substitutions */
    return 2;
}

LUA_API int luaopen_fan_fifo(lua_State *L);

LUA_API int luaopen_fan_http_core(lua_State *L);

LUA_API int luaopen_fan_httpd_core(lua_State *L);

LUA_API int luaopen_fan_tcpd(lua_State *L);

LUA_API int luaopen_fan_udpd(lua_State *L);

LUA_API int luaopen_fan_udpd(lua_State *L);

LUA_API int luaopen_fan_popen(lua_State *L);

LUA_API int luaopen_fan(lua_State *L);

LUA_API int luaopen_fan_objectbuf_core(lua_State *L);

LUA_API int luaopen_fan_stream_core(lua_State *L);

LUALIB_API int luaopen_md4(lua_State *L);
LUALIB_API int luaopen_md5(lua_State *L);
LUALIB_API int luaopen_sha1(lua_State *L);
LUALIB_API int luaopen_sha224(lua_State *L);
LUALIB_API int luaopen_sha256(lua_State *L);
LUALIB_API int luaopen_sha384(lua_State *L);
LUALIB_API int luaopen_sha512(lua_State *L);
LUALIB_API int luaopen_ripemd160(lua_State *L);

LUALIB_API int luaopen_openssl(lua_State*L);
LUALIB_API int luaopen_base64(lua_State*L);

LUALIB_API int luaopen_brotli(lua_State *L);

LUA_API int luaopen_curlimp(lua_State *L);

LUA_API int luaopen_gcm(lua_State *L);

LUA_API int luaopen_file_scan(lua_State *L);

#ifndef PAL_NO_TUNNEL
LUA_API int luaopen_tunpacket_core(lua_State *L);
LUA_API int luaopen_dnspacket_core(lua_State *L);
#endif


#include "lsqlite3.h"
#include "ltime64.h"
#include <lua53/lstate.h>

_Atomic size_t lua_mem_total = 0;

static int utlua_cpuinfo(lua_State *L);

static void *l_alloc (void *ud, void *ptr, size_t osize, size_t nsize) {
    lua_mem_total -= pal_alloc_size(ptr);

    if (nsize == 0) {
        pal_alloc_free(ptr);
        return NULL;
    } else {
        void *new_ptr = pal_alloc_realloc(ptr, nsize);
        lua_mem_total += pal_alloc_size(new_ptr);
        return new_ptr;
    }
}

extern _Atomic size_t libevent_mem_total;

static int lua_malloc_zone_statistics(lua_State *L){
    return pal_push_malloc_zone_statistics(L);
}

#include "sqlite3.h"

static int lua_sqlite3_memory_used(lua_State *L){
    lua_pushinteger(L, sqlite3_memory_used());
    return 1;
}

static int lua_libevent_event_base_get_num_events(lua_State *L){
    lua_newtable(L);
    
    lua_pushinteger(L, event_base_get_num_events(event_mgr_base(), EVENT_BASE_COUNT_ACTIVE));
    lua_setfield(L, -2, "count_active");

    lua_pushinteger(L, event_base_get_num_events(event_mgr_base(), EVENT_BASE_COUNT_ADDED));
    lua_setfield(L, -2, "count_added");

    return 1;
}

#import <assert.h>

static int lua_cpu_usage(lua_State *L)
{
    return pal_push_cpu_usage(L);
}

lua_State* utlua_open_state(){
//    malloc_zone_t *zone = malloc_create_zone(0, 0);
//    malloc_set_zone_name(zone, "LUA_ZONE");
    lua_State *L = lua_newstate(l_alloc, NULL);
//    lua_State *L = luaL_newstate();
    
    luaL_openlibs(L);
    
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    
    static const luaL_Reg preloadedlibs[] = {
        {"fan.http.core", luaopen_fan_http_core},
        {"fan.httpd.core", luaopen_fan_httpd_core},
        {"fan.tcpd", luaopen_fan_tcpd},
        {"fan.udpd", luaopen_fan_udpd},
        {"fan.popen", luaopen_fan_popen},
        {"fan.fifo", luaopen_fan_fifo},

        {"fan", luaopen_fan},
        {"fan.objectbuf.core", luaopen_fan_objectbuf_core},
        {"fan.stream.core", luaopen_fan_stream_core},
        {"fan.evdns", luaopen_fan_evdns},

        /* Strict JSON (luafan/src/json.c). */
        {"json", luaopen_json},
        {"lfs", luaopen_lfs},
        {"zlib", luaopen_zlib},
        {"lsqlite3", luaopen_lsqlite3},
        {"time64", luaopen_time64},
#ifndef PAL_NO_TUNNEL
        {"tunpacket.core", luaopen_tunpacket_core},
        {"dnspacket.core", luaopen_dnspacket_core},
        {"dnspacket_core", luaopen_dnspacket_core},
#endif
        {"icmp_sender", luaopen_icmp_sender},
        {"wildcard_matcher", luaopen_wildcard_matcher},

        {"md4", luaopen_md4},
        {"md5", luaopen_md5},
        {"sha1", luaopen_sha1},
        {"sha224", luaopen_sha224},
        {"sha256", luaopen_sha256},
        {"sha384", luaopen_sha384},
        {"sha512", luaopen_sha512},
        {"ripemd160", luaopen_ripemd160},

#if !defined(__ANDROID__) || __ANDROID_API__ >= 28
        {"iconv", luaopen_iconv},
#endif

        {"base64", luaopen_base64},
        {"openssl", luaopen_openssl},
        {"brotli", luaopen_brotli},
        {"curlimp", luaopen_curlimp},
        {"gcm", luaopen_gcm},
        {"file_scan", luaopen_file_scan},
        {NULL, NULL}
    };
    const luaL_Reg *lib;
    
    for (lib = preloadedlibs; lib->func; lib++) {
        lua_pushcfunction(L, lib->func);
        lua_setfield(L, -2, lib->name);
    }
    lua_pop(L, 2);  /* remove _PRELOAD table */
    
    lua_register(L, "cpuinfo", utlua_cpuinfo);
    lua_register(L, "malloc_zone_statistics", lua_malloc_zone_statistics);
    lua_register(L, "cpu_usage", lua_cpu_usage);
    lua_register(L, "sqlite3_memory_used", lua_sqlite3_memory_used);
    lua_register(L, "event_base_get_num_events", lua_libevent_event_base_get_num_events);

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    lua_getfield(L, -1, LUA_STRLIBNAME);  /* get _LOADED[string] */
    if (lua_istable(L, -1)) {
        lua_remove(L, -2);

        lua_pushcclosure(L, str_trim, 0);
        lua_setfield(L, -2, "trim");
        
        lua_pushcclosure(L, str_ptime, 0);
        lua_setfield(L, -2, "ptime");

        lua_pushcclosure(L, str_replace, 0);
        lua_setfield(L, -2, "replace");

        lua_pop(L, 1);
    }else {
        lua_pop(L, 2);
    }
    
    return L;
}

extern void LuaError(lua_State *L, int errfunc);

#define MAX_APPID_LENGTH 255
#define OVER_LOAD_BUFFER_LEN 10
struct ExtraInfo {
    lua_State *L;            /* we'll use this field as the key */
    char appId[MAX_APPID_LENGTH + 1];
    double time_count;
    double overload_begin[OVER_LOAD_BUFFER_LEN];
    double overload_end[OVER_LOAD_BUFFER_LEN];
    UT_hash_handle hh; /* makes this structure hashable */
};

static double timeout_gettime(void) {
    struct timeval v;
    gettimeofday(&v, (struct timezone *) NULL);
    /* Unix Epoch time (time since January 1, 1970 (UTC)) */
    return v.tv_sec + v.tv_usec/1.0e6;
}

struct ExtraInfo *infos = NULL;

#define CPUINFO_DURATION 5

static int utlua_cpuinfo(lua_State *L) {
    double now = timeout_gettime();
    lua_lock(L);
    lua_newtable(L);
    struct ExtraInfo *p = NULL, *tmp = NULL;
    int index = 1;
    HASH_ITER(hh, infos, p, tmp) {
        int i = 0;
        double count = 0;
        for (; i < OVER_LOAD_BUFFER_LEN; i++) {
            double st = p->overload_begin[i] < now - CPUINFO_DURATION ? now - CPUINFO_DURATION : p->overload_begin[i];
            double ed = p->overload_end[i] < now - CPUINFO_DURATION ? now - CPUINFO_DURATION : p->overload_end[i];
            count += ed - st;
        }
        lua_newtable(L);

        lua_gc(p->L, LUA_GCCOLLECT, 0);

        lua_pushstring(L, p->appId);
        lua_rawseti(L, -2, 1);

        lua_pushnumber(L, count / CPUINFO_DURATION);
        lua_rawseti(L, -2, 2);

        int counti = lua_gc(p->L, LUA_GCCOUNT, 0);
        int countb = lua_gc(p->L, LUA_GCCOUNTB, 0);

        lua_pushinteger(L, counti << 10 | countb);
        lua_rawseti(L, -2, 3);

        lua_pushnumber(L, p->time_count);
        lua_rawseti(L, -2, 4);

        StateData *sd = *((StateData **)lua_getextraspace(p->L));
        lua_pushinteger(L, sd->thread_count);
        lua_rawseti(L, -2, 5);

        lua_rawseti(L, -2, index++);
    }
    lua_unlock(L);
    return 1;
}

static int EXTRA_INFO_KEY = 0;
#define EXTRA_INFO "EXTRA_INFO"

static int utlua_extra_info_gc(lua_State *L) {
    struct ExtraInfo **pinfo = luaL_checkudata(L, 1, EXTRA_INFO);
    lua_lock(L);
    HASH_DEL(infos, *pinfo);
    lua_unlock(L);
    return 0;
}

static struct ExtraInfo *utlua_extra_info_get(lua_State *mainthread) {
    struct ExtraInfo *info = NULL;
    HASH_FIND_PTR(infos, &mainthread, info);

    if (!info) {
        info = malloc(sizeof(struct ExtraInfo));
        memset(info, 0, sizeof(struct ExtraInfo));
        info->L = mainthread;

        lua_lock(mainthread);
        lua_getfield(mainthread, LUA_REGISTRYINDEX, "appId");
        size_t len = 0;
        const char *appId = lua_tolstring(mainthread, -1, &len);
        memcpy(info->appId, appId, len > MAX_APPID_LENGTH ? MAX_APPID_LENGTH : len);
        lua_pop(mainthread, 1);

        HASH_ADD_PTR(infos, L, info);

        lua_pushlightuserdata(mainthread, &EXTRA_INFO_KEY);
        struct ExtraInfo **pinfo = lua_newuserdata(mainthread, sizeof(struct ExtraInfo *));

        luaL_newmetatable(mainthread, EXTRA_INFO);
        lua_pushstring(mainthread, "__gc");
        lua_pushcfunction(mainthread, &utlua_extra_info_gc);
        lua_rawset(mainthread, -3);

        lua_setmetatable(mainthread, -2);
        *pinfo = info;
        lua_rawset(mainthread, LUA_REGISTRYINDEX);

        lua_unlock(mainthread);
    }

    return info;
}

int caplua_resume(lua_State *co, lua_State *from, int count){
    int costatus = lua_status(co);
    if (costatus == LUA_YIELD) {
        // continue resume;
    } else if (costatus == LUA_OK) {
        lua_Debug ar;
        if (lua_getstack(co, 0, &ar) > 0){
            return costatus;
        } else if (lua_gettop(co) == 0){
            return costatus;
        } else {
            // continue resume;
        }
    } else {
        return costatus;
    }

    lua_State *ROOT = utlua_mainthread(co);
    incrRef(ROOT);

//    double startTime = timeout_gettime();
    int status = lua_resume(co, from, count);
//    double stopTime = timeout_gettime();

    lua_lock(ROOT);
    if (status > LUA_YIELD) {
        LuaError(co, 1);
    }
//    struct ExtraInfo *info = utlua_extra_info_get(ROOT);
//
//    memmove(info->overload_begin, info->overload_begin + 1, sizeof(double) * (OVER_LOAD_BUFFER_LEN - 1));
//    memmove(info->overload_end, info->overload_end + 1, sizeof(double) * (OVER_LOAD_BUFFER_LEN - 1));
//    info->overload_begin[OVER_LOAD_BUFFER_LEN - 1] = startTime;
//    info->overload_end[OVER_LOAD_BUFFER_LEN - 1] = stopTime;
//
//    info->time_count += stopTime - startTime;
    lua_unlock(ROOT);

    decrRef(ROOT);
    
    return status;
}
