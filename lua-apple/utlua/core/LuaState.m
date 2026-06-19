// LuaState.m — thin ObjC wrapper around a lua_State.
// LuanMac / OpenLuan (MIT)

#import "LuaState.h"

#import "lua.h"
#import "utlua.h" // LuaRefCount, lua_lock / lua_unlock

@implementation LuaState {
    lua_State *_L;
}

- (instancetype)initWithState:(lua_State *)L {
    self = [super init];
    if (self) {
        _L = L;
    }
    return self;
}

- (lua_State *)state {
    return _L;
}

- (int)refCount {
    return LuaRefCount(_L);
}

- (void)setRegistryValue:(NSString *)value forKey:(NSString *)key {
    lua_lock(_L);
    lua_pushstring(_L, [key UTF8String]);
    lua_pushstring(_L, [value UTF8String]);
    lua_rawset(_L, LUA_REGISTRYINDEX);
    lua_unlock(_L);
}

@end
