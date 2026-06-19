#ifndef caplua_h
#define caplua_h

#include "utlua.h"

lua_State* utlua_open_state(void);
int caplua_resume(lua_State *co, lua_State *from, int count);

#endif
