#!/bin/bash
# build_xcframeworks.sh — build third-party xcframework dependencies used by
# the LuanMac app / luan CLI targets:
#
#   OpenSSL          -> Frameworks/libcrypto.xcframework + libssl.xcframework
#                       (+ Frameworks/openssl-headers for generated headers)
#   curl-impersonate -> Frameworks/libcurl-impersonate.xcframework
#                       (prebuilt dylibs + complete curl headers)
#
# The normal all/macos targets use libcurl-impersonate as the single libcurl
# backend for both ordinary fan.http and browser-fingerprinted curlimp calls.
# Legacy vanilla libcurl/nghttp2 builders remain available through explicit
# curl, nghttp2, or vanilla targets, but are not part of the normal build.
# OpenSSL is compiled from the submodule (lua-apple/third_party/openssl,
# pinned openssl-3.0.18) in a temp copy so the submodule worktree stays clean.
# curl-impersonate is fetched as pre-built dylibs (arm64 + x86_64) from the
# lexiforest/curl-impersonate GitHub release, lipo'd into a fat dylib with
# install_name @rpath, and wrapped into an xcframework with its curl headers.
#
# All outputs are build artifacts (gitignored), not committed.
#
# Prereqs: macOS host, Xcode command line tools (perl, make, clang, lipo,
# xcodebuild, install_name_tool, curl, tar, shasum). Network access to
# github.com for the tarballs and the curl-impersonate dylibs.
#
# Usage:
#   ./scripts/build_xcframeworks.sh [TARGET]
#     all        : openssl (all platforms) + curlimp (default)
#     macos      : openssl macOS slices + curlimp (CI fast path)
#     ios|ios-sim|tvos|catalyst : openssl only, for that platform
#     openssl    : openssl only (all platforms)
#     openssl-macos : OpenSSL macOS slices only (no nghttp2/curl rebuild)
#     nghttp2    : legacy vanilla HTTP/2 framework only
#     curl       : legacy vanilla libcurl framework only
#     vanilla    : legacy nghttp2 + vanilla libcurl build
#     curlimp    : curl-impersonate only
#
# Verify after run:
#   otool -L Frameworks/libcurl-impersonate.xcframework/macos-arm64_x86_64/libcurl-impersonate.4.dylib
#   grep OPENSSL_VERSION_TEXT \
#     Frameworks/openssl-headers/include/openssl/opensslv.h
#   grep LIBCURL_VERSION \
#     Frameworks/libcurl.xcframework/macos-arm64_x86_64/Headers/curl/curlver.h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/Frameworks"
CORES="$(sysctl -n hw.ncpu)"

# Pinned versions. Match jasonacox/Build-OpenSSL-cURL where applicable so the
# resulting libcurl.a / libnghttp2.a are ABI-interchangeable with the historic
# manual drop-in that lived in Frameworks/ before this script covered them.
CURL_VERSION="${CURL_VERSION:-8.17.0}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.68.0}"

# sha256 of the upstream tarballs. Must match the signed release artifact; see
# https://github.com/curl/curl/releases and https://github.com/nghttp2/nghttp2/releases
# Verified 2026-10-10 for the pinned versions above by fetching the tarballs
# and recomputing the digest.
CURL_SHA256="${CURL_SHA256:-e8e74cdeefe5fb78b3ae6e90cd542babf788fa9480029cfcee6fd9ced42b7910}"
NGHTTP2_SHA256="${NGHTTP2_SHA256:-2c16ffc588ad3f9e2613c3fad72db48ecb5ce15bc362fcc85b342e48daf51013}"

WORK_OPENSSL=""
WORK_CURIMP=""
WORK_VANILLA=""
KEEP_OPENSSL=0
KEEP_VANILLA=0

cleanup() {
  if [ -n "$WORK_OPENSSL" ]; then
    if [ "$KEEP_OPENSSL" = "1" ]; then
      echo "[openssl] debug build tree kept at: $WORK_OPENSSL"
    else
      rm -rf "$WORK_OPENSSL"
    fi
  fi
  if [ -n "$WORK_VANILLA" ]; then
    if [ "$KEEP_VANILLA" = "1" ]; then
      echo "[vanilla] debug build tree kept at: $WORK_VANILLA"
    else
      rm -rf "$WORK_VANILLA"
    fi
  fi
  if [ -n "$WORK_CURIMP" ]; then
    rm -rf "$WORK_CURIMP"
  fi
}
trap cleanup EXIT

# ===========================================================================
# OpenSSL -> libcrypto.xcframework + libssl.xcframework
# ===========================================================================

OPENSSL_SRC="$PROJECT_ROOT/lua-apple/third_party/openssl"

# ---- shared configure flags: static libs, no tests.
# NOTE: OpenSSL 3.x Configure has NO no-apps option (apps is not a disablable
# feature); we only `make libcrypto.a libssl.a`, so apps never gets built.
COMMON_FLAGS=(no-shared no-tests)

# build_one <name> <configure-target> [extra-args...]
# Runs Configure+make in a fresh copy, leaves libcrypto.a/libssl.a in
# $WORK_OPENSSL/<name>/ and include/openssl headers in $WORK_OPENSSL/<name>/include.
# Configure/make output goes to logs; on failure the log tail is printed and
# the debug tree is kept (KEEP_OPENSSL=1).
build_one() {
  local name="$1"; shift
  local target="$1"; shift
  local dir="$WORK_OPENSSL/$name"
  local copy="$WORK_OPENSSL/src-$name"
  rm -rf "$copy"
  cp -R "$SRC_COPY" "$copy"
  mkdir -p "$dir"
  (
    cd "$copy"
    echo "[openssl] configure $name ($target) ..."
    if ! ./Configure "$target" "${COMMON_FLAGS[@]}" "$@" \
        --prefix="$dir" --openssldir="$dir" >"$WORK_OPENSSL/$name.configure.log" 2>&1; then
      echo "[openssl] ERROR: Configure failed for $name:" >&2
      tail -n 40 "$WORK_OPENSSL/$name.configure.log" >&2
      exit 1
    fi
    # OpenSSL 3.x generates many public headers (crypto.h, ssl.h, ...) from
    # .in templates via the `build_generated` target. `make libcrypto.a
    # libssl.a` targets build_libs_nodep directly and skips that step, so the
    # headers must be generated explicitly first. -j1: the generated headers
    # are interdependent; generation is perl-only and fast.
    echo "[openssl] make $name (build_generated headers) ..."
    if ! make -j1 build_generated >"$WORK_OPENSSL/$name.make.log" 2>&1; then
      echo "[openssl] ERROR: make build_generated failed for $name (log tail):" >&2
      tail -n 40 "$WORK_OPENSSL/$name.make.log" >&2
      KEEP_OPENSSL=1
      exit 1
    fi
    echo "[openssl] make $name (libcrypto.a libssl.a) ..."
    if ! make -j"$CORES" libcrypto.a libssl.a >>"$WORK_OPENSSL/$name.make.log" 2>&1; then
      echo "[openssl] ERROR: make failed for $name (log tail):" >&2
      tail -n 40 "$WORK_OPENSSL/$name.make.log" >&2
      echo "[openssl] diagnostics:" >&2
      echo "[openssl]   crypto.h generated: $([ -f include/openssl/crypto.h ] && echo yes || echo NO)" >&2
      echo "[openssl]   opensslconf.h generated: $([ -f include/openssl/opensslconf.h ] && echo yes || echo NO)" >&2
      echo "[openssl]   Makefile present: $([ -f Makefile ] && echo yes || echo NO)" >&2
      echo "[openssl]   configdata.pm present: $([ -f configdata.pm ] && echo yes || echo NO)" >&2
      KEEP_OPENSSL=1
      exit 1
    fi
    cp libcrypto.a libssl.a "$dir/"
    # Preserve the openssl/ subdir: `cp -R src dst` flattens src into dst when
    # dst does not exist, so create dst first, then copy into it.
    mkdir -p "$dir/include"
    cp -R include/openssl "$dir/include/"
  ) || { KEEP_OPENSSL=1; return 1; }
}

build_openssl() {
  local PLATFORM="${1:-all}"
  [ -f "$OPENSSL_SRC/Configure" ] || {
    echo "[openssl] ERROR: submodule not checked out: $OPENSSL_SRC" >&2
    echo "[openssl]   fix: git submodule update --init --recursive" >&2
    exit 1
  }
  echo "[openssl] building OpenSSL $(grep -E '^(MAJOR|MINOR|PATCH)=' "$OPENSSL_SRC/VERSION.dat" | tr '\n' ' ' | sed 's/ =/=/g') into $OUT_DIR"
  WORK_OPENSSL="$(mktemp -d -t openssl-xcf.XXXXXX)"
  # Copy source so Configure/make artifacts never dirty the submodule worktree.
  SRC_COPY="$WORK_OPENSSL/src"
  cp -R "$OPENSSL_SRC" "$SRC_COPY"

  local SLICES_LIBCRYPTO=()
  local SLICES_LIBSSL=()
  # Headers land in Frameworks/openssl-headers/include (build output, gitignored).
  # See the "Collect the generated public headers" section below for why the
  # xcframework itself is created without -headers.
  local HEADERS_DIR="$OUT_DIR/openssl-headers/include"

  build_macos() {
    # Keep the static OpenSSL objects compatible with the app deployment
    # target. Without this, newer Xcode SDKs may stamp objects with the
    # host SDK version (for example macOS 26.0), causing linker warnings
    # when LuanMac targets macOS 14.0.
    MACOSX_DEPLOYMENT_TARGET=14.0 build_one macos-arm64 darwin64-arm64-cc \
      CFLAGS="-mmacosx-version-min=14.0"
    MACOSX_DEPLOYMENT_TARGET=14.0 build_one macos-x86_64 darwin64-x86_64-cc \
      CFLAGS="-mmacosx-version-min=14.0"
    lipo -create -output "$WORK_OPENSSL/libcrypto-macos.a" \
      "$WORK_OPENSSL/macos-arm64/libcrypto.a" "$WORK_OPENSSL/macos-x86_64/libcrypto.a"
    lipo -create -output "$WORK_OPENSSL/libssl-macos.a" \
      "$WORK_OPENSSL/macos-arm64/libssl.a" "$WORK_OPENSSL/macos-x86_64/libssl.a"
    SLICES_LIBCRYPTO+=("$WORK_OPENSSL/libcrypto-macos.a")
    SLICES_LIBSSL+=("$WORK_OPENSSL/libssl-macos.a")
  }

  build_ios() {
    build_one ios-arm64 ios64-xcrun
    SLICES_LIBCRYPTO+=("$WORK_OPENSSL/ios-arm64/libcrypto.a")
    SLICES_LIBSSL+=("$WORK_OPENSSL/ios-arm64/libssl.a")
  }

  build_ios_sim() {
    # OpenSSL 3.x rejects `iossimulator-xcrun -arch <arch>` with
    # "target already defined - iossimulator-xcrun (offending arg: arm64)":
    # the generic iossimulator-xcrun target already pins the arch via the
    # SDK's own clang invocation, so passing a second -arch via Configure
    # trips the duplicate-target guard. Thread the arch through CC
    # instead (mirrors build_catalyst), using an explicit -target so the
    # driver picks the right triple for each simulator slice.
    local tgt_arm="-target arm64-apple-ios15.0-simulator"
    local tgt_x64="-target x86_64-apple-ios15.0-simulator"
    build_one ios-sim-arm64 iossimulator-xcrun CC="clang $tgt_arm"
    build_one ios-sim-x86_64 iossimulator-xcrun CC="clang $tgt_x64"
    lipo -create -output "$WORK_OPENSSL/libcrypto-iossim.a" \
      "$WORK_OPENSSL/ios-sim-arm64/libcrypto.a" "$WORK_OPENSSL/ios-sim-x86_64/libcrypto.a"
    lipo -create -output "$WORK_OPENSSL/libssl-iossim.a" \
      "$WORK_OPENSSL/ios-sim-arm64/libssl.a" "$WORK_OPENSSL/ios-sim-x86_64/libssl.a"
    SLICES_LIBCRYPTO+=("$WORK_OPENSSL/libcrypto-iossim.a")
    SLICES_LIBSSL+=("$WORK_OPENSSL/libssl-iossim.a")
  }

  build_tvos() {
    build_one tvos-arm64 tvos64-xcrun
    SLICES_LIBCRYPTO+=("$WORK_OPENSSL/tvos-arm64/libcrypto.a")
    SLICES_LIBSSL+=("$WORK_OPENSSL/tvos-arm64/libssl.a")
  }

  # Mac Catalyst: no dedicated OpenSSL target; use darwin64 targets with an
  # explicit macabi clang target. Experimental — see
  # https://github.com/openssl/openssl/issues/15498 for background.
  build_catalyst() {
    local tgt_arm="-target arm64-apple-ios15.0-macabi"
    local tgt_x64="-target x86_64-apple-ios15.0-macabi"
    build_one catalyst-arm64 darwin64-arm64-cc CC="clang $tgt_arm"
    build_one catalyst-x86_64 darwin64-x86_64-cc CC="clang $tgt_x64"
    lipo -create -output "$WORK_OPENSSL/libcrypto-catalyst.a" \
      "$WORK_OPENSSL/catalyst-arm64/libcrypto.a" "$WORK_OPENSSL/catalyst-x86_64/libcrypto.a"
    lipo -create -output "$WORK_OPENSSL/libssl-catalyst.a" \
      "$WORK_OPENSSL/catalyst-arm64/libssl.a" "$WORK_OPENSSL/catalyst-x86_64/libssl.a"
    SLICES_LIBCRYPTO+=("$WORK_OPENSSL/libcrypto-catalyst.a")
    SLICES_LIBSSL+=("$WORK_OPENSSL/libssl-catalyst.a")
  }

  case "$PLATFORM" in
    macos)    build_macos ;;
    ios)      build_ios ;;
    ios-sim)  build_ios_sim ;;
    tvos)
      # OpenSSL 3.x removed the dedicated tvos64-xcrun target; the legacy
      # recipe does not configure. Nothing in project.yml currently builds
      # for tvOS, so the default 'all' invocation skips this slice. Users
      # that need it must update build_tvos() for OpenSSL 3.x first (likely
      # via iphoneos-cross + CC="clang -target arm64-apple-tvos<ver>").
      echo "[openssl] WARN: build_tvos is not updated for OpenSSL 3.x and will fail" >&2
      build_tvos ;;
    catalyst) build_catalyst ;;
    all)
      build_macos
      build_ios
      build_ios_sim
      # tvos skipped: see 'tvos' case above. Catalyst is tricky; enable
      # when needed. See build_catalyst above.
      # build_tvos
      # build_catalyst
      ;;
    *) echo "unknown platform: $PLATFORM (macos|ios|ios-sim|tvos|catalyst|all)" >&2; exit 1 ;;
  esac

  # Collect the generated public headers (openssl/ subdir preserved) from the
  # macos-arm64 slice into Frameworks/openssl-headers/include. This set includes
  # the generated opensslconf.h and configuration.h. The xcframework itself is
  # created WITHOUT -headers: both app targets link it and would otherwise race
  # to emit $(BUILT_PRODUCTS_DIR)/include/openssl/* ("Multiple commands produce").
  # Instead targets get the headers via HEADER_SEARCH_PATHS pointing here.
  rm -rf "$OUT_DIR/openssl-headers"
  mkdir -p "$HEADERS_DIR/openssl"
  if ! cp -R "$WORK_OPENSSL/macos-arm64/include/openssl/." "$HEADERS_DIR/openssl/"; then
    echo "[openssl] ERROR: headers not found under $WORK_OPENSSL/macos-arm64/include/openssl" >&2
    KEEP_OPENSSL=1
    exit 1
  fi

  echo "[openssl] creating libcrypto.xcframework ..."
  rm -rf "$OUT_DIR/libcrypto.xcframework"
  local CMD=(xcodebuild -create-xcframework)
  for a in "${SLICES_LIBCRYPTO[@]}"; do
    CMD+=(-library "$a")
  done
  CMD+=(-output "$OUT_DIR/libcrypto.xcframework")
  "${CMD[@]}" >"$WORK_OPENSSL/xcf-crypto.log" 2>&1

  echo "[openssl] creating libssl.xcframework ..."
  rm -rf "$OUT_DIR/libssl.xcframework"
  CMD=(xcodebuild -create-xcframework)
  for a in "${SLICES_LIBSSL[@]}"; do
    CMD+=(-library "$a")
  done
  CMD+=(-output "$OUT_DIR/libssl.xcframework")
  "${CMD[@]}" >"$WORK_OPENSSL/xcf-ssl.log" 2>&1

  echo ""
  echo "[openssl] done:"
  echo "  $OUT_DIR/libcrypto.xcframework"
  echo "  $OUT_DIR/libssl.xcframework"
  echo "[openssl] verify:"
  if [ -f "$HEADERS_DIR/openssl/opensslv.h" ]; then
    grep "OPENSSL_VERSION_TEXT" "$HEADERS_DIR/openssl/opensslv.h" | head -1
  else
    echo "[openssl] ERROR: headers missing at $HEADERS_DIR/openssl/" >&2
    KEEP_OPENSSL=1
    exit 1
  fi
}

# ===========================================================================
# vanilla libnghttp2 + libcurl (OpenSSL backend)
#     -> Frameworks/libnghttp2.xcframework
#     -> Frameworks/libcurl.xcframework (headers staged inside)
#
# Both are linked statically from pinned upstream tarballs. libcurl links
# against the libssl/libcrypto that OpenSSL stage produced in WORK_OPENSSL
# (same submodule-pinned 3.0.x build the main app ships), so the resulting
# libcurl.a is ABI-interchangeable with Frameworks/libssl.xcframework.
# ===========================================================================

CURL_TARBALL_URL="https://github.com/curl/curl/releases/download/curl-$(echo "$CURL_VERSION" | tr . _)/curl-$CURL_VERSION.tar.gz"
NGHTTP2_TARBALL_URL="https://github.com/nghttp2/nghttp2/releases/download/v$NGHTTP2_VERSION/nghttp2-$NGHTTP2_VERSION.tar.gz"

# fetch_tarball <url> <sha256> <dest-path>
# Downloads the URL (if dest-path does not exist) and verifies sha256. Fails
# hard on checksum mismatch so a tampered mirror cannot sneak into the build.
fetch_tarball() {
  local url="$1"; shift
  local want_sha="$1"; shift
  local dst="$1"; shift
  if [ -f "$dst" ]; then
    local have_sha
    have_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
    if [ "$have_sha" = "$want_sha" ]; then
      echo "[vanilla] cached: $dst ($want_sha)"
      return 0
    fi
    echo "[vanilla] stale cache (sha mismatch), re-downloading: $dst" >&2
    rm -f "$dst"
  fi
  echo "[vanilla] fetch $url"
  curl -fL --retry 3 -o "$dst" "$url"
  local got_sha
  got_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
  if [ "$got_sha" != "$want_sha" ]; then
    echo "[vanilla] ERROR: sha256 mismatch for $url" >&2
    echo "  want: $want_sha" >&2
    echo "  got : $got_sha" >&2
    rm -f "$dst"
    exit 1
  fi
  echo "[vanilla] sha256 ok: $got_sha"
}

# Ensure OpenSSL has been built in this run (vanilla curl links against it).
# When build_openssl was already called in the same invocation we reuse its
# WORK_OPENSSL output; otherwise we trigger a macos-only openssl build first.
ensure_openssl_for_vanilla() {
  if [ -n "$WORK_OPENSSL" ] \
      && [ -f "$WORK_OPENSSL/macos-arm64/libcrypto.a" ] \
      && [ -f "$WORK_OPENSSL/macos-x86_64/libcrypto.a" ]; then
    echo "[vanilla] reusing openssl build at: $WORK_OPENSSL"
    return 0
  fi
  echo "[vanilla] openssl not yet built in this invocation; building macos slices first"
  build_openssl macos
}

# build_nghttp2_slice <slice-name> <arch> <min-macos-version>
# Configures nghttp2 for a single macOS arch, installs the static lib and
# headers into $WORK_VANILLA/nghttp2/<slice-name>/.
build_nghttp2_slice() {
  local name="$1"      # macos-arm64 | macos-x86_64
  local arch="$2"      # arm64 | x86_64
  local min_osx="$3"   # 11.0 | 10.15
  local src="$WORK_VANILLA/nghttp2-src-$name"
  local prefix="$WORK_VANILLA/nghttp2/$name"
  local log="$WORK_VANILLA/nghttp2-$name.log"
  rm -rf "$src"
  mkdir -p "$src" "$prefix"
  tar -xzf "$WORK_VANILLA/nghttp2.tar.gz" --strip-components=1 -C "$src"
  (
    cd "$src"
    local cflags="-arch $arch -mmacosx-version-min=$min_osx -O2"
    echo "[nghttp2] configure $name ($arch min=$min_osx) ..."
    if ! CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="-arch $arch" \
        ./configure --prefix="$prefix" \
            --host="$arch-apple-darwin" \
            --disable-shared --enable-static \
            --enable-lib-only --disable-threads \
            --without-libxml2 --without-jansson --without-libev \
            --without-libevent-openssl --without-libcares \
            --without-openssl --without-cython \
            --without-systemd --disable-python-bindings \
            --disable-examples --disable-app \
            >"$log" 2>&1; then
      echo "[nghttp2] ERROR: configure failed for $name (log tail):" >&2
      tail -n 40 "$log" >&2
      KEEP_VANILLA=1
      exit 1
    fi
    echo "[nghttp2] make install $name ..."
    if ! make -j"$CORES" install >>"$log" 2>&1; then
      echo "[nghttp2] ERROR: make install failed for $name (log tail):" >&2
      tail -n 40 "$log" >&2
      KEEP_VANILLA=1
      exit 1
    fi
  ) || { KEEP_VANILLA=1; return 1; }
}

build_nghttp2() {
  echo "[nghttp2] version=$NGHTTP2_VERSION"
  if [ -z "$WORK_VANILLA" ]; then
    WORK_VANILLA="$(mktemp -d -t vanilla-xcf.XXXXXX)"
    echo "[vanilla] work=$WORK_VANILLA"
  fi
  fetch_tarball "$NGHTTP2_TARBALL_URL" "$NGHTTP2_SHA256" \
      "$WORK_VANILLA/nghttp2.tar.gz"

  build_nghttp2_slice macos-arm64 arm64 11.0
  build_nghttp2_slice macos-x86_64 x86_64 10.15

  echo "[nghttp2] lipo arm64 + x86_64 ..."
  local FAT="$WORK_VANILLA/libnghttp2-macos.a"
  lipo -create -output "$FAT" \
      "$WORK_VANILLA/nghttp2/macos-arm64/lib/libnghttp2.a" \
      "$WORK_VANILLA/nghttp2/macos-x86_64/lib/libnghttp2.a"
  echo "[nghttp2] fat: $(lipo -info "$FAT")"

  echo "[nghttp2] creating libnghttp2.xcframework ..."
  rm -rf "$OUT_DIR/libnghttp2.xcframework"
  xcodebuild -create-xcframework \
      -library "$FAT" \
      -output "$OUT_DIR/libnghttp2.xcframework" \
    >"$WORK_VANILLA/nghttp2-xcf.log" 2>&1

  echo "[nghttp2] done: $OUT_DIR/libnghttp2.xcframework"
}

# build_curl_slice <slice-name> <arch> <min-macos-version>
# Needs: openssl install prefix (WORK_OPENSSL/<same-slice>) and nghttp2
# install prefix (WORK_VANILLA/nghttp2/<same-slice>) already populated.
build_curl_slice() {
  local name="$1"      # macos-arm64 | macos-x86_64
  local arch="$2"
  local min_osx="$3"
  local src="$WORK_VANILLA/curl-src-$name"
  local prefix="$WORK_VANILLA/curl/$name"
  local log="$WORK_VANILLA/curl-$name.log"
  local openssl_prefix="$WORK_OPENSSL/$name"
  local nghttp2_prefix="$WORK_VANILLA/nghttp2/$name"
  if [ ! -f "$openssl_prefix/libssl.a" ]; then
    echo "[curl] ERROR: openssl prefix missing libssl.a: $openssl_prefix" >&2
    exit 1
  fi
  if [ ! -f "$nghttp2_prefix/lib/libnghttp2.a" ]; then
    echo "[curl] ERROR: nghttp2 prefix missing libnghttp2.a: $nghttp2_prefix" >&2
    exit 1
  fi
  rm -rf "$src"
  mkdir -p "$src" "$prefix"
  tar -xzf "$WORK_VANILLA/curl.tar.gz" --strip-components=1 -C "$src"
  (
    cd "$src"
    local cflags="-arch $arch -mmacosx-version-min=$min_osx -O2"
    cflags="$cflags -I$openssl_prefix/include -I$nghttp2_prefix/include"
    local ldflags="-arch $arch -L$openssl_prefix -L$nghttp2_prefix/lib"
    echo "[curl] configure $name ($arch min=$min_osx) ..."
    # Feature switches match what the historic hand-rolled libcurl.a shipped
    # (OpenSSL backend, http2 via nghttp2, websockets on; no ldap, psl,
    # brotli, zstd, libssh2, librtmp, libidn2, docs). Pass PKG_CONFIG_PATH
    # so curl's configure can resolve openssl/nghttp2 metadata, and
    # explicit --with-openssl/--with-nghttp2 so it never falls back to a
    # system install under /opt/homebrew.
    if ! CFLAGS="$cflags" LDFLAGS="$ldflags" \
        PKG_CONFIG_PATH="$openssl_prefix/lib/pkgconfig:$nghttp2_prefix/lib/pkgconfig" \
        ./configure --prefix="$prefix" \
            --host="$arch-apple-darwin" \
            --disable-shared --enable-static \
            --with-openssl="$openssl_prefix" \
            --with-nghttp2="$nghttp2_prefix" \
            --enable-websockets \
            --enable-ipv6 --enable-threaded-resolver \
            --disable-ldap --disable-ldaps \
            --disable-manual --disable-docs \
            --without-libpsl --without-brotli --without-zstd \
            --without-libssh2 --without-librtmp --without-libidn2 \
            --without-ngtcp2 --without-nghttp3 --without-quiche \
            --without-ca-bundle --without-ca-path \
            >"$log" 2>&1; then
      echo "[curl] ERROR: configure failed for $name (log tail):" >&2
      tail -n 40 "$log" >&2
      KEEP_VANILLA=1
      exit 1
    fi
    echo "[curl] make install $name ..."
    if ! make -j"$CORES" install >>"$log" 2>&1; then
      echo "[curl] ERROR: make install failed for $name (log tail):" >&2
      tail -n 40 "$log" >&2
      KEEP_VANILLA=1
      exit 1
    fi
  ) || { KEEP_VANILLA=1; return 1; }
}

build_curl_vanilla() {
  echo "[curl] version=$CURL_VERSION"
  if [ -z "$WORK_VANILLA" ]; then
    WORK_VANILLA="$(mktemp -d -t vanilla-xcf.XXXXXX)"
    echo "[vanilla] work=$WORK_VANILLA"
  fi
  ensure_openssl_for_vanilla
  # nghttp2 is a hard dependency; build it if the current invocation did not
  # already produce it.
  if [ ! -f "$WORK_VANILLA/nghttp2/macos-arm64/lib/libnghttp2.a" ] \
      || [ ! -f "$WORK_VANILLA/nghttp2/macos-x86_64/lib/libnghttp2.a" ]; then
    build_nghttp2
  fi

  fetch_tarball "$CURL_TARBALL_URL" "$CURL_SHA256" \
      "$WORK_VANILLA/curl.tar.gz"

  build_curl_slice macos-arm64 arm64 11.0
  build_curl_slice macos-x86_64 x86_64 10.15

  echo "[curl] lipo arm64 + x86_64 ..."
  local FAT="$WORK_VANILLA/libcurl-macos.a"
  lipo -create -output "$FAT" \
      "$WORK_VANILLA/curl/macos-arm64/lib/libcurl.a" \
      "$WORK_VANILLA/curl/macos-x86_64/lib/libcurl.a"
  echo "[curl] fat: $(lipo -info "$FAT")"

  # Stage headers (arm64 slice; headers are arch-independent) for the
  # xcframework. Both the main luan CLI and the curl-impersonate-mcp
  # subprocess target include curl/curl.h via HEADER_SEARCH_PATHS on this
  # xcframework.
  local STAGE_HEADERS="$WORK_VANILLA/curl-Headers"
  rm -rf "$STAGE_HEADERS"
  mkdir -p "$STAGE_HEADERS/curl"
  cp "$WORK_VANILLA/curl/macos-arm64/include/curl/"*.h "$STAGE_HEADERS/curl/"

  echo "[curl] creating libcurl.xcframework ..."
  rm -rf "$OUT_DIR/libcurl.xcframework"
  xcodebuild -create-xcframework \
      -library "$FAT" \
      -headers "$STAGE_HEADERS" \
      -output "$OUT_DIR/libcurl.xcframework" \
    >"$WORK_VANILLA/curl-xcf.log" 2>&1

  echo "[curl] done: $OUT_DIR/libcurl.xcframework"
  echo "[curl] verify:"
  if [ -f "$OUT_DIR/libcurl.xcframework/macos-arm64_x86_64/Headers/curl/curlver.h" ]; then
    grep "LIBCURL_VERSION " \
        "$OUT_DIR/libcurl.xcframework/macos-arm64_x86_64/Headers/curl/curlver.h" | head -1
  fi
}

build_vanilla() {
  build_nghttp2
  build_curl_vanilla
}

# ===========================================================================
# curl-impersonate -> libcurl-impersonate.xcframework
# ===========================================================================

CI_VERSION="${CI_VERSION:-v2.2.3}"

build_curlimp() {
  echo "[curlimp] version=$CI_VERSION"
  WORK_CURIMP="$(mktemp -d -t curlimp-xcf.XXXXXX)"
  echo "[curlimp] work=$WORK_CURIMP"
  echo "[curlimp] out=$OUT_DIR/libcurl-impersonate.xcframework"

  local BASE="https://github.com/lexiforest/curl-impersonate/releases/download/$CI_VERSION"

  fetch_and_extract() {
    local arch="$1"    # arm64 | x86_64
    local url="$BASE/libcurl-impersonate-$CI_VERSION.$arch-macos.tar.gz"
    local dst="$WORK_CURIMP/$arch"
    mkdir -p "$dst"
    echo "[curlimp] fetch $url"
    curl -fL --retry 3 -o "$WORK_CURIMP/$arch.tar.gz" "$url"
    tar -xzf "$WORK_CURIMP/$arch.tar.gz" -C "$dst"
  }

  fetch_and_extract arm64
  fetch_and_extract x86_64

  # lexiforest tar layout: libcurl-impersonate.4.dylib + include/curl/*.h (versions vary; probe).
  find_dylib() {
    local dir="$1"
    local f
    f="$(find "$dir" -maxdepth 4 -name 'libcurl-impersonate.4.dylib' -type f | head -n1)"
    if [ -z "$f" ]; then
      # older tarballs might use libcurl-impersonate-chrome.4.dylib or plain libcurl.4.dylib
      f="$(find "$dir" -maxdepth 4 -name 'libcurl-impersonate*.dylib' -type f | head -n1)"
    fi
    if [ -z "$f" ]; then
      echo "[curlimp] ERROR: no libcurl-impersonate*.dylib in $dir" >&2
      find "$dir" -type f >&2
      exit 1
    fi
    echo "$f"
  }

  local ARM_DY
  ARM_DY="$(find_dylib "$WORK_CURIMP/arm64")"
  local X64_DY
  X64_DY="$(find_dylib "$WORK_CURIMP/x86_64")"

  echo "[curlimp] arm64  dylib: $ARM_DY"
  echo "[curlimp] x86_64 dylib: $X64_DY"
  echo "[curlimp] arm64 otool -L:"
  otool -L "$ARM_DY" | sed 's/^/    /'
  echo "[curlimp] x86_64 otool -L:"
  otool -L "$X64_DY" | sed 's/^/    /'

  # The impersonate library is the single libcurl backend, so publish its
  # complete curl headers in the xcframework. This avoids a second vanilla
  # libcurl header/library tree and lets ordinary fan.http and curlimp use
  # the same ABI and global state.
  local HEADERS_SRC
  HEADERS_SRC="$(find "$WORK_CURIMP/arm64" -maxdepth 4 -type d -name curl | head -n1)"
  if [ -z "$HEADERS_SRC" ] || [ ! -f "$HEADERS_SRC/curl.h" ]; then
    echo "[curlimp] ERROR: cannot find curl/*.h in arm64 tarball" >&2
    exit 1
  fi
  echo "[curlimp] headers: $HEADERS_SRC"
  local STAGE_HEADERS="$WORK_CURIMP/Headers"
  mkdir -p "$STAGE_HEADERS/curl"
  cp "$HEADERS_SRC"/*.h "$STAGE_HEADERS/curl/"

  # Lipo into fat dylib.
  local FAT="$WORK_CURIMP/libcurl-impersonate.4.dylib"
  lipo -create -output "$FAT" "$ARM_DY" "$X64_DY"
  echo "[curlimp] fat: $(lipo -info "$FAT")"

  # Rewrite install_name so App can load it from bundle Frameworks/ via @rpath.
  install_name_tool -id "@rpath/libcurl-impersonate.4.dylib" "$FAT"

  # Rebuild xcframework (fat dylib + headers).
  rm -rf "$OUT_DIR/libcurl-impersonate.xcframework"
  xcodebuild -create-xcframework \
      -library "$FAT" \
      -headers "$STAGE_HEADERS" \
      -output "$OUT_DIR/libcurl-impersonate.xcframework" \
    >"$WORK_CURIMP/xcf.log" 2>&1

  echo ""
  echo "[curlimp] done: $OUT_DIR/libcurl-impersonate.xcframework"
  echo "[curlimp] verify:"
  local INNER
  INNER="$(find "$OUT_DIR/libcurl-impersonate.xcframework" -name 'libcurl-impersonate.4.dylib' | head -n1)"
  otool -L "$INNER" | sed 's/^/    /'
  echo "[curlimp] install_name:"
  otool -D "$INNER" | sed 's/^/    /'
}

# ===========================================================================
# dispatch
# ===========================================================================

PLATFORM="${1:-all}"
case "$PLATFORM" in
  openssl)       build_openssl all ;;
  openssl-macos) build_openssl macos ;;
  nghttp2)       build_nghttp2 ;;
  curl)          build_curl_vanilla ;;
  vanilla)       build_vanilla ;;
  curlimp)       build_curlimp ;;
  all)
    build_openssl all
    build_curlimp
    ;;
  macos)
    build_openssl macos
    build_curlimp
    ;;
  ios|ios-sim|tvos|catalyst)
    # Non-macOS platforms only build openssl (vanilla + curlimp are macOS-only
    # artefacts: curlimp has prebuilt dylibs for macOS only, and vanilla curl
    # here is targeted at the Mac luan CLI + curl-impersonate-mcp subprocess).
    build_openssl "$PLATFORM"
    ;;
  *) echo "unknown target: $PLATFORM (all|macos|ios|ios-sim|tvos|catalyst|openssl|openssl-macos|nghttp2|curl|vanilla|curlimp)" >&2; exit 1 ;;
esac

echo ""
echo "[build_xcframeworks] done"
