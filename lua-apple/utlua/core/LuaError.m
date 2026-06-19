// LuaError.m — minimal Lua error reporter.
// Replaces the ObjC-bridge-bound LuaError from LuaObjCBridge.m (which depended
// on lua_objc_topropertylist); kept pure C API + Foundation logging only.
// LuanMac / OpenLuan (MIT)

#import "LuaError.h"
#import <Foundation/Foundation.h>

#import "lua.h"
#import "lauxlib.h"

void LuaError(lua_State *L, int errfunc) {
    @autoreleasepool {
        (void)errfunc;
        const char *msg = lua_tostring(L, -1);
        if (!msg) msg = "(non-string error)";
        luaL_traceback(L, L, msg, 1);
        const char *trace = lua_tostring(L, -1);
        NSLog(@"LuaError: %s", trace ? trace : msg);
        lua_pop(L, 1); // pop traceback; keep the original error on the stack
    }
}
