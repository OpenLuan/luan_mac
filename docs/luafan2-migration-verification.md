# luafan2 macOS migration verification

本次迁移将 LuanMac 的宿主边界和 Xcode source graph 切换到 `lua-apple/luafan2`。

## 已验证

- `LuanMac.xcodeproj`：Xcode MCP `BuildProject(windowtab3)` 成功。
- runtime：`scripts/build_runtime.sh` 成功，生成 224 个 Lua 文件和 18 个 JavaScript 文件；Node 语法检查通过。
- QA HTTP：根目录和 `/_login.html` 返回 200。
- QA 单元：`/_test/unit?unit=file_scan_symlink` 三项全部通过。
- QA 启动：进程已启动并监听 8081；账号初始化脚本访问 `/_api/auth/status` 返回 404，需后续按当前 QA 认证路由单独修正，未观察到 runtime 崩溃。

## 迁移边界

- coroutine 异步引用使用 `fan_coro_park()` / `fan_coro_wake()`，registry 引用在 resume 返回后释放。
- Lua close 前由 `fan_clear_lua_states()` 清理 runtime 缓存状态。
- `icmp_sender.m` 已移除旧 `REF_STATE_*` 宏依赖。
- 本次变更未执行 push。
