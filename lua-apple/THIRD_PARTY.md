# Vendored third-party (lua-apple)

| Component | Location | Upstream pin | Notes |
|-----------|----------|--------------|--------|
| Lua 5.3.3 | `lua53/` | git submodule github.com/lua/lua @ `v5.3.3` | clean upstream (no local `.diff`); lock via `luauser` + `-DLUA_USER_H` |
| luauser | `luauser.c`, `luauser.h` | first-party | `LUA_USER_H` hooks |
| luafan | `luafan/` | submodule luafan/luafan | git submodule |
| libevent 2.1.12-stable | `libevent/` | git submodule github.com/libevent/libevent @ `release-2.1.12-stable` | macOS generated headers in `platform/libevent-config/macos/` (not upstream); see LICENSE |
| Brotli | `third_party/brotli/` | git submodule github.com/google/brotli @ `v1.1.0` lineage | compiled from `third_party/brotli/c`; binding: `utlua/brotli/lua_brotli.c` (first-party) |
| lua-openssl | `third_party/lua-openssl/` (compiled directly) | git submodule github.com/OpenLuan/lua-openssl @ branch `luan-eaa7923` | fork of zhaozg/lua-openssl @ `eaa7923` + local fix (see below); deps submodules `deps/auxiliar` (lua-auxiliar) + `deps/lua-compat` (lua-compat-5.3) ship inside it |
| SQLite amalgamation | `utlua/sqlite3.*` | sqlite.org | public domain |
| Other utlua | lfs, lzlib, … | see root `THIRD_PARTY_NOTICES.md` | |

## Submodules

- `luafan/` → https://github.com/luafan/luafan.git
- `libevent/` → https://github.com/libevent/libevent.git (pinned to
  `release-2.1.12-stable`); generated headers stay in
  `platform/libevent-config/macos/`
- `lua53/` → https://github.com/lua/lua.git (pinned to `v5.3.3`); no
  source patches — see `patches/lua-5.3.3/README.md`
- `third_party/brotli/` → https://github.com/google/brotli.git; compiled from
  its `c/` subtree, while the Lua binding stays first-party in
  `utlua/brotli/lua_brotli.c`
- `third_party/lua-openssl/` → https://github.com/OpenLuan/lua-openssl.git
  pinned to branch `luan-eaa7923` (fork of zhaozg/lua-openssl @ `eaa7923`
  plus the LUAN crash fix below). The Xcode targets compile `src/` and the
  `deps/auxiliar` submodule directly — there is no patched copy under
  `utlua/openssl/` anymore. Fetch recursively:
  `git submodule update --init --recursive` (lua-openssl itself has
  `deps/auxiliar` + `deps/lua-compat` nested submodules).

## lua-openssl local delta

Compiled directly from the fork submodule; the only delta vs upstream
`zhaozg/lua-openssl` @ `eaa7923` is one crash fix in `src/xname.c`:

- `openssl_new_xname()` now validates each array element with `lua_istable`
  before iterating it. Previously `x509.name.new{ "CN=x" }` (non-table array
  element) passed the outer table checks and `lua_next` treated the string as
  a table, dereferencing a NULL array pointer in `luaH_next` and crashing the
  whole process (`pcall` cannot catch a segfault).
