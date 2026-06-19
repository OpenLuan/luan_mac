// LuaState.h — thin ObjC wrapper around a lua_State.
// LuanMac / OpenLuan (MIT)
//
// This is the ONLY host-facing interface of utlua/core: the SwiftUI app and
// CLI hold a LuaState while the service runs. All the OC object bridging
// (LuaTable/LuaFunction/LuaProxy/...) was unused and has been removed.

#import <Foundation/Foundation.h>

struct lua_State;

@interface LuaState : NSObject

// Wrap an existing lua_State (owned by the caller — the host drives
// refcounting/close via utlua incrRef/decrRef, not this wrapper).
- (instancetype)initWithState:(struct lua_State *)L;

- (struct lua_State *)state;

// Number of live references to the Lua state (LuaRefCount).
- (int)refCount;

// Set registry[key] = value (both NSString; used for http.cainfo / http.capath).
- (void)setRegistryValue:(NSString *)value forKey:(NSString *)key;

@end
