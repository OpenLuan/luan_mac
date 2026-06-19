#!/bin/bash
# build_xcframeworks.sh — build all third-party xcframework dependencies used
# by the LuanMac app / luan CLI targets:
#
#   OpenSSL          -> Frameworks/libcrypto.xcframework + libssl.xcframework
#                       (+ Frameworks/openssl-headers for the generated headers)
#   curl-impersonate -> Frameworks/libcurl-impersonate.xcframework
#
# OpenSSL is compiled from the submodule (lua-apple/third_party/openssl, pinned
# openssl-3.0.18) in a temp copy so the submodule worktree stays clean.
# libcurl-impersonate is fetched as pre-built dylibs (arm64 + x86_64) from the
# lexiforest/curl-impersonate GitHub release, lipo'd into a fat dylib with
# install_name @rpath, and wrapped into an xcframework.
#
# All outputs are build artifacts (gitignored), not committed.
#
# Prereqs: macOS host, Xcode command line tools (perl, make, clang, lipo,
# xcodebuild, install_name_tool, curl, tar). Network access to github.com for
# the curl-impersonate dylibs.
#
# Usage:
#   ./scripts/build_xcframeworks.sh [all|macos|ios|ios-sim|tvos|catalyst|openssl|curlimp]
#     (default: all — OpenSSL for all platforms + curl-impersonate)
#     macos   : OpenSSL macOS slices + curl-impersonate (CI fast path)
#     openssl : OpenSSL only (all platforms)
#     curlimp : curl-impersonate only
#
# Verify after run:
#   otool -L Frameworks/libcurl-impersonate.xcframework/macos-arm64_x86_64/libcurl-impersonate.4.dylib
#   grep OPENSSL_VERSION_TEXT \
#     Frameworks/openssl-headers/include/openssl/opensslv.h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/Frameworks"
CORES="$(sysctl -n hw.ncpu)"

WORK_OPENSSL=""
WORK_CURIMP=""
KEEP_OPENSSL=0

cleanup() {
  if [ -n "$WORK_OPENSSL" ]; then
    if [ "$KEEP_OPENSSL" = "1" ]; then
      echo "[openssl] debug build tree kept at: $WORK_OPENSSL"
    else
      rm -rf "$WORK_OPENSSL"
    fi
  fi
  [ -n "$WORK_CURIMP" ] && rm -rf "$WORK_CURIMP"
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
    build_one macos-arm64 darwin64-arm64-cc
    build_one macos-x86_64 darwin64-x86_64-cc
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
    build_one ios-sim-arm64 iossimulator-xcrun -arch arm64
    build_one ios-sim-x86_64 iossimulator-xcrun -arch x86_64
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
    tvos)     build_tvos ;;
    catalyst) build_catalyst ;;
    all)
      build_macos
      build_ios
      build_ios_sim
      build_tvos
      # Catalyst is tricky; enable when needed. See build_catalyst above.
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
# curl-impersonate -> libcurl-impersonate.xcframework
# ===========================================================================

CI_VERSION="${CI_VERSION:-v2.1.0}"

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

  # Ship the impersonate headers inside the xcframework so nothing else
  # in the tree has to keep a separate libcurl.xcframework around just for
  # curl/*.h. Both archs have identical headers; prefer the arm64 tarball.
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
  openssl) build_openssl all ;;
  curlimp) build_curlimp ;;
  all|macos|ios|ios-sim|tvos|catalyst)
    build_openssl "$PLATFORM"
    build_curlimp
    ;;
  *) echo "unknown target: $PLATFORM (all|macos|ios|ios-sim|tvos|catalyst|openssl|curlimp)" >&2; exit 1 ;;
esac

echo ""
echo "[build_xcframeworks] done"
