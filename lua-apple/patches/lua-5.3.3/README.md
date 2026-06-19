# Lua 5.3.3 — no source patches

`lua-apple/lua53` is the official git submodule (`github.com/lua/lua` tag
`v5.3.3`) with **zero** local edits to the upstream tree.

## Thread safety without patching Lua

1. **Compile-time hooks** — `-DLUA_USER_H="<luauser.h>"` and first-party
   `lua-apple/luauser.c` (reentrant global `lua_lock` for luafan workers).
   Linux Docker uses the equivalent `fan_lua_lock` — do not link both.
2. **Call-site discipline** — hold `lua_lock` around registry ref work
   (luafan `utlua.h`: `REF_STATE_SET`, `CLEAR_REF`, `fan_cb_setup`, …).
   Stock `luaL_ref` / `luaL_unref` unlock between internal `lua_*` calls;
   an outer lock (reentrant) keeps the freelist update atomic. Prefer
   those macros or a thin wrapper in *our* code — not a fork of `lauxlib.c`.

After `git submodule update` of `lua53`, the worktree should stay clean.
Do not commit inside the submodule.

## Dropped historical diffs (do not reintroduce)

| Former patch | Why dropped |
|--------------|-------------|
| `lauxlib` lock inside `luaL_ref`/`unref` | Redundant when (1)+(2) hold; call sites should lock |
| `loslib` disable `os.execute` on iOS | LuanMac is macOS-only |
| `lvm` mixed number equality via `tonumber` | No day-to-day benefit vs stock 5.3.3 `tointeger` |

## Bare `luaL_ref` / `luaL_unref` audit (snapshot)

Heuristic scan (no `lua_lock` in the previous ~10 lines). Many hits are
still safe if the whole function already runs under the lock, or only on
the Lua main thread — treat as a checklist, not automatic bugs.

| Area | Approx. bare hits | Notes |
|------|-------------------|--------|
| `luafan/src/http.c` | audited | request setup/error refs are covered by exported `http_*` wrappers' outer `lua_lock`; completion cleanup refs are explicitly locked; fixed the two post-unlock resume cleanup unrefs (`ResumeInfo` allocation failure and `resume_cb`) |
| `utlua/luacurlimp.c` | audited | curl-impersonate uses the same curl multi/event/resume shape as `http.c`; fixed coroutine ref/unref cleanup and result-stack writes around completion/resume paths |
| `luafan/src/httpd*.c` | audited | request/WebSocket guard refs now use `CLEAR_REF`; WebSocket resume argument pushes and self-ref creation are explicitly locked |
| `luafan/src/udpd_event.c`, `luafan.c`, `utlua.c` | audited | UDP callback refs and luafan main loop refs are locked; `utlua.c` core helpers are called under existing locks on Lua 5.3 path |
| `luafan/src/mariadb/*` | audited | async wait callbacks now enter through a locked trampoline; coroutine/table helper refs are explicitly locked |
| `utlua/lsqlite3.c` | audited | sqlite callbacks are synchronous, but local wrappers now lock every registry ref/unref call site |
| `utlua/lzlib.c`, `openssl/ots.c` | audited | local wrappers now lock every registry ref/unref call site |
| `utlua/core/*.m` (ObjC bridge) | audited | existing call paths mostly held the lock; fixed post-resume thread-ref cleanup and async ObjC coroutine ref creation |
| `pal/pal_ios.m`, `pal/pal_lua_bridge.c` | audited | mac/iOS target actually compiles these PAL files; bridge registry refs are explicitly locked |
| `pal/pal_linux.c`, `pal/pal_android.c` | removed | non-mac platform stubs were untested and are no longer kept in this tree |

When touching concurrent code: use `REF_STATE_*` / `CLEAR_REF` or
`lua_lock` … `luaL_ref` … `lua_unlock` explicitly.
