# Third-Party Notices

LuanMac includes or links the following third-party software. Their licenses
apply to those components; they are not replaced by the root MIT license.

This list is intentionally practical (paths as used in this tree). Upstream
URLs may move; pin versions in git history / submodule commits when present.

## Bundled / compiled into the app or CLI

| Component | Path (typical) | License (summary) | Upstream |
|-----------|----------------|-------------------|----------|
| Lua 5.3.3 | `lua-apple/lua53/` (submodule; no local source patches) | MIT | https://www.lua.org/ / https://github.com/lua/lua `v5.3.3` |
| luafan | `lua-apple/luafan/` (submodule) | MIT | https://github.com/luafan/luafan |
| libevent 2.1.12-stable | `lua-apple/libevent/` (submodule) + `platform/libevent-config/macos/` | BSD (see `libevent/LICENSE`) | https://github.com/libevent/libevent `release-2.1.12-stable` |
| Brotli C library | `lua-apple/third_party/brotli/` (submodule; compiled from `c/`) | MIT (`brotli/LICENSE`) | https://github.com/google/brotli |
| SQLite amalgamation | `lua-apple/utlua/sqlite3.c` (+ headers) | Public domain | https://www.sqlite.org/ |
| lsqlite3 | `lua-apple/utlua/lsqlite3.c` | MIT-style (see file header) | LuaSQLite3 / community ports |
| lua-openssl toolkit | `lua-apple/third_party/lua-openssl/` (submodule @ `OpenLuan/lua-openssl` branch `luan-eaa7923`, compiled directly) | MIT (`openssl/LICENSE`) | https://github.com/OpenLuan/lua-openssl (fork of zhaozg/lua-openssl) |
| LuaFileSystem (lfs) | `lua-apple/utlua/lfs.c` | MIT | https://github.com/lunarmodules/luafilesystem |
| lzlib | `lua-apple/utlua/lzlib.c` | MIT-style (see file) | Tiago Dionizio / community |
| lua-iconv binding | `lua-apple/utlua/luaiconv.c` | See file header | community |
| uthash | `lua-apple/utlua/uthash.h` | BSD revision | https://github.com/troydhanson/uthash |
| time64 | `lua-apple/utlua/time64*.c` | See Schwern notice in file | Michael G Schwern |
| OpenSSL-based digest glue | `lua-apple/utlua/algorithm/ldigest.c`, `lmd5.*` | Public domain (lhf) | Luiz Henrique de Figueiredo |
| base64 (ISC/IBM portions) | `lua-apple/utlua/base64.c` | ISC + IBM grant (see file) | Historical ISC/IBM code |
| CA certificates bundle | `runtime/cacert.pem` (when present) | MPL-2.0 (curl/cacert) | https://curl.se/docs/caextract.html |

First-party native helpers in this tree (not third-party), e.g. `luagcm.c`,
`luacurlimp.c`, `caplua.c`, `luauser.c` / `luauser.h` (Lua `LUA_USER_H` lock
hooks; not part of upstream Lua), `pal/*`, `icmp_sender.*`, `wildcard_matcher.*`,
are covered by the root **MIT** license unless a file says otherwise.

## Linked prebuilt binaries (not always in git)

Built or vendored outside the main source tree; required to link the macOS
targets. Obtain via project scripts / system packages; do not assume they are
MIT.

| Component | Typical location | Notes |
|-----------|------------------|--------|
| OpenSSL (libcrypto / libssl) | `Frameworks/libcrypto.xcframework`, `Frameworks/libssl.xcframework` | OpenSSL / Apache-style license — see OpenSSL notices |
| curl-impersonate | `Frameworks/libcurl-impersonate.xcframework` | curl + impersonate project licenses; build via `scripts/build_xcframeworks.sh` |
| system libs | `libz`, `libiconv`, `libresolv`, `libldap` (SDK) | Apple SDK / OS terms |

## Runtime Lua tree

`runtime/` is a **build output** (merged from luafan modules, webase, and luan
sources via `scripts/build_runtime.sh`). Third-party JS (e.g. marked) inside `runtime/web`
keeps its own headers. Prefer rebuilding from source repositories rather than
hand-editing `runtime/`.

## Submodules

See `.gitmodules`. At minimum:

- `lua-apple/luafan` → https://github.com/luafan/luafan.git
- `lua-apple/libevent` → https://github.com/libevent/libevent.git
  (pinned to `release-2.1.12-stable`; generated headers stay in
  `platform/libevent-config/macos/`)
- `lua-apple/lua53` → https://github.com/lua/lua.git (pinned to `v5.3.3`;
  clean upstream; multi-thread lock via first-party `luauser` /
  `-DLUA_USER_H`, not patches — see `patches/lua-5.3.3/README.md`)
- `lua-apple/third_party/brotli` → https://github.com/google/brotli.git
  (compiled from its `c/` subtree; Lua binding stays in `utlua/brotli/`)
- `lua-apple/third_party/lua-openssl` → https://github.com/OpenLuan/lua-openssl.git
  pinned to branch `luan-eaa7923` (fork of zhaozg/lua-openssl @ `eaa7923` +
  one crash fix in `src/xname.c`); compiled directly from the submodule —
  `git submodule update --init --recursive` also fetches its nested
  `deps/auxiliar` (lua-auxiliar) and `deps/lua-compat` (lua-compat-5.3).

## Incomplete upstream LICENSE copies

Some vendored trees historically shipped without a full upstream `LICENSE` file
next to the sources (e.g. brotli, lua-openssl). Treat the **upstream project
license** as authoritative; this document is the in-repo index. When converting
a component to a git submodule, the upstream tree’s LICENSE travels with the
submodule (already the case for luafan, libevent, and lua53).
