//
//  luauser.h — Lua 5.3 user-state hooks (global lua_lock for multi-thread luafan)
//  LuanMac / OpenLuan
//
//  Injected via -DLUA_USER_H="<luauser.h>" (stock lua.h). Not part of upstream Lua.
//

#ifndef LUAN_LUAUSER_H
#define LUAN_LUAUSER_H

#define GLOBAL_LOCK

#undef luai_userstateopen
#define luai_userstateopen(L)       LuaLockInitial(L)

#undef luai_userstatethread
#define luai_userstatethread(L,L1)  LuaLockInitialThread(L,L1)

#undef luai_userstateclose
#define luai_userstateclose(L)      LuaLockFinalState(L)

#undef luai_userstatefree
#define luai_userstatefree(L,L1)      LuaLockFinalThread(L,L1)

#include <pthread.h>

typedef struct StateData StateData;

struct StateData{
#ifndef GLOBAL_LOCK
    pthread_mutex_t lock;
#endif
    int count;
    int thread_count;
};

#ifdef lua_lock
#undef lua_lock
#endif
#define lua_lock(L)    LockMainState(L)
#define lua_unlock(L)  UnLockMainState(L)

void LuaLockInitial(lua_State * L);
void LuaLockInitialThread(lua_State * L, lua_State * co);
void LuaLockFinalState(lua_State * L);
void LuaLockFinalThread(lua_State * L, lua_State *co);

void incrRef(lua_State *L);
void decrRef(lua_State *L);

lua_State* GetMainState(lua_State *L);

void LockMainState(lua_State *L);
void UnLockMainState(lua_State *L);

void LuaGlobalLock(void);
void LuaGlobalUnlock(void);

// Release/re-acquire every recursive level of the global Lua lock around a
// blocking main-thread event loop. See luauser.c.
int LuaLockSuspendForLoop(void);
void LuaLockResumeAfterLoop(int depth);

void LuaError(lua_State *L, int);

LUALIB_API int luaL_typerror (lua_State *L, int narg, const char *tname);

void LuaLockWatchdogStart(void);
void LuaLockWatchdogStop(void);

int  LuaLockDepthGet(void);
void LuaLockDepthSet(int depth);

// Returns StateData->count for the given lua_State (or 0 if L is NULL).
int LuaRefCount(lua_State *L);

#endif /* LUAN_LUAUSER_H */
