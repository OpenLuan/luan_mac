#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LuaBridge : NSObject

@property (nonatomic, copy, nullable) void (^outputHandler)(NSString *chunk);

- (void)runWithDocumentRoot:(NSString *)documentRoot
                        env:(nullable NSDictionary<NSString *, NSString *> *)env;

// Execute a Lua chunk with the same embedded runtime and module search path.
// Set LUAN_EXEC_SCRIPT or LUAN_EXEC_CODE in env before calling.
- (void)runScriptWithDocumentRoot:(NSString *)documentRoot
                               env:(nullable NSDictionary<NSString *, NSString *> *)env;

- (void)stop;

// Returns StateData->count for the current Lua state (0 if not running).
- (int)refCount;

// Process-wide metrics. Safe to call from any thread.
// luaMemKB returns 0 when no bridge is running.
// rssBytes returns the current process resident footprint.
// cpuPercent returns whole-process CPU usage averaged since the previous call;
// the first call seeds the baseline and returns 0.
+ (size_t)currentLuaMemKB;
+ (size_t)currentRSSBytes;
+ (double)currentCPUPercent;

@end

void LuanSetLogToStderr(BOOL enabled);
void LuanOpenLogFile(NSString *documentRoot);
void LuanCloseLogFile(void);
void LuanLogWrite(NSString *msg);

NS_ASSUME_NONNULL_END
