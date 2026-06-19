#include "ltime64.h"
#include "lauxlib.h"
#include "time64.h"

static int getfield (lua_State *L, const char *key, int d) {
    int res, isnum;
    lua_getfield(L, -1, key);
    res = (int)lua_tointegerx(L, -1, &isnum);
    if (!isnum) {
        if (d < 0)
            return luaL_error(L, "field " LUA_QS " missing in date table", key);
        res = d;
    }
    lua_pop(L, 1);
    return res;
}

static int getboolfield (lua_State *L, const char *key) {
    int res;
    lua_getfield(L, -1, key);
    res = lua_isnil(L, -1) ? -1 : lua_toboolean(L, -1);
    lua_pop(L, 1);
    return res;
}

int time64_time(lua_State *L) {
    Time64_T t;
    if (lua_isnoneornil(L, 1))  /* called without args? */
        t = time(NULL);  /* get current time */
    else {
        struct TM ts;
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_settop(L, 1);  /* make sure table is at the top */
        ts.tm_sec = getfield(L, "sec", 0);
        ts.tm_min = getfield(L, "min", 0);
        ts.tm_hour = getfield(L, "hour", 12);
        ts.tm_mday = getfield(L, "day", -1);
        ts.tm_mon = getfield(L, "month", -1) - 1;
        ts.tm_year = getfield(L, "year", -1) - 1900;
        ts.tm_isdst = getboolfield(L, "isdst");
        t = mktime64(&ts);
    }
    if (t == (time_t)(-1))
        lua_pushnil(L);
    else
        lua_pushnumber(L, (lua_Number)t);
    return 1;
}

static const luaL_Reg httplib[] = {
    {"time",      time64_time},
    {NULL, NULL}
};

int luaopen_time64(lua_State *L){
    luaL_openlib(L, "time64", httplib, 0);

    return 1;
}
