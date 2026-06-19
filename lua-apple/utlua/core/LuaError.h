// LuaError.h — minimal error helper for host bridge + caplua (pure C).
// LuanMac / OpenLuan (MIT)
#ifndef LuaError_h
#define LuaError_h

struct lua_State;

// Print the error on the stack top (with a traceback) via NSLog.
// Leaves the original error value on the stack (pushes+ pops its own traceback).
void LuaError(struct lua_State *L, int errfunc);

#endif /* LuaError_h */
