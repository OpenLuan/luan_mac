#!/usr/bin/env bash
# Start LuanCLI (luan) with RUNTIME_DIR = <luan_mac>/runtime and a temp document-root.
# No env vars required: secrets and port defaults are set inside.
# Host resolves runtime via documentRoot/runtime (symlink created below).
#
# Usage:
#   ./scripts/run_cli_temp.sh                 # foreground, fixed tmp workspace, port 8081
#   ./scripts/run_cli_temp.sh --bg            # background; DOCROOT/cli.pid + wait ready
#   ./scripts/run_cli_temp.sh --port 19090
#   LUAN_BIN=/path/to/luan ./scripts/run_cli_temp.sh
#   ./scripts/run_cli_temp.sh --docroot /tmp/my-ws
#
# Default DOCROOT is fixed: ${TMPDIR:-/tmp}/luan-ws (reused across runs; not mktemp).
#
# Stop background:
#   kill "$(cat "$DOCROOT/cli.pid")"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-$PROJECT_ROOT/runtime}"

PORT=8081
HOST=127.0.0.1
WORKERS=2
BG=0
DEBUG=1
# Constrained sandbox by default (no host bash / DOCROOT escape for root).
# Opt in with --unrestricted or SANDBOX_UNRESTRICTED=1.
SANDBOX_UNRESTRICTED="${SANDBOX_UNRESTRICTED:-0}"
# Fixed path so restarts land on the same workspace (override with DOCROOT / --docroot).
# Strip trailing slashes on TMPDIR so macOS …/T/ + luan-ws does not become …/T//luan-ws
# (that double slash used to fail sandbox path prefix checks after resolve).
_TMPDIR_BASE="${TMPDIR:-/tmp}"
_TMPDIR_BASE="${_TMPDIR_BASE%/}"
DEFAULT_DOCROOT="${_TMPDIR_BASE}/luan-ws"
DOCROOT="${DOCROOT:-}"
LUAN_BIN="${LUAN_BIN:-}"

# Align with tests/run.sh defaults (override via env if you want)
JWT_SECRET="${JWT_SECRET:-test_jwt_secret_key_for_ci}"
ACTIVATION_KEY="${ACTIVATION_KEY:-testkey123}"
WS_TOKEN="${WS_TOKEN:-}"
PURGE_TOKEN="${PURGE_TOKEN:-}"

usage() {
    cat <<'EOF'
Usage: run_cli_temp.sh [options]

  --port <n>         HTTP port (default: 8081)
  --host <addr>      Bind address (default: 127.0.0.1)
  --workers <n>      Worker threads (default: 2)
  --bg               Background (pid in $DOCROOT/cli.pid, wait until HTTP ready)
  --no-debug         Do not pass --debug
  --unrestricted     Pass --sandbox-unrestricted (root may use bash / escape DOCROOT)
  --no-unrestricted  Keep constrained sandbox (default; explicit no-op for scripts)
  --docroot <path>   Document root (default: fixed ${TMPDIR:-/tmp}/luan-ws)
  --bin <path>       Path to luan CLI binary
  -h, --help         Show help

Optional env: LUAN_BIN, DOCROOT, RUNTIME_DIR, JWT_SECRET, ACTIVATION_KEY, WS_TOKEN, PURGE_TOKEN,
  SANDBOX_UNRESTRICTED=1 (same as --unrestricted)
RUNTIME_DIR defaults to <luan_mac>/runtime (build output).
Default DOCROOT is a fixed directory under TMPDIR (reused; not mktemp).
Sandbox defaults to constrained (no --sandbox-unrestricted).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --bg) BG=1; shift ;;
        --no-debug) DEBUG=0; shift ;;
        --unrestricted|--sandbox-unrestricted) SANDBOX_UNRESTRICTED=1; shift ;;
        --no-unrestricted) SANDBOX_UNRESTRICTED=0; shift ;;
        --docroot) DOCROOT="$2"; shift 2 ;;
        --bin) LUAN_BIN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ ! -f "$RUNTIME_DIR/core.lua" ]; then
    echo "error: missing $RUNTIME_DIR/core.lua (run scripts/build_runtime.sh first)" >&2
    exit 1
fi

find_luan_bin() {
    if [ -n "$LUAN_BIN" ]; then
        if [ -x "$LUAN_BIN" ]; then
            echo "$LUAN_BIN"
            return 0
        fi
        echo "error: LUAN_BIN not executable: $LUAN_BIN" >&2
        return 1
    fi
    local c found root
    for c in \
        "$PROJECT_ROOT/build/Debug/luan" \
        "$PROJECT_ROOT/build/Release/luan" \
        "$PROJECT_ROOT/DerivedData/Build/Products/Debug/luan" \
        "$PROJECT_ROOT/DerivedData/Build/Products/Release/luan"
    do
        if [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    # Default Xcode DerivedData; set DERIVED_DATA to add a custom location.
    for root in \
        "$HOME/Library/Developer/Xcode/DerivedData" \
        ${DERIVED_DATA:+"$DERIVED_DATA"}
    do
        [ -d "$root" ] || continue
        found="$(ls -t \
            "$root"/LuanMac-*/Build/Products/Debug/luan \
            "$root"/LuanMac-*/Build/Products/Release/luan \
            "$root"/LuanMac-*/Build/Products/Debug/LuanMac.app/Contents/MacOS/luan \
            "$root"/LuanMac-*/Build/Products/Release/LuanMac.app/Contents/MacOS/luan \
            2>/dev/null | head -1 || true)"
        if [ -n "$found" ] && [ -x "$found" ]; then
            echo "$found"
            return 0
        fi
    done
    return 1
}

if ! LUAN_BIN="$(find_luan_bin)"; then
    echo "error: cannot find luan CLI binary." >&2
    echo "  Build Xcode scheme 'luan', or: LUAN_BIN=/path/to/luan $0" >&2
    exit 1
fi

if [ -z "$DOCROOT" ]; then
    DOCROOT="$DEFAULT_DOCROOT"
fi
mkdir -p "$DOCROOT"

# Ensure DOCROOT/runtime points at this build output. A stale symlink may
# still contain core.lua, so it must be recreated instead of being accepted.
if [ -L "$DOCROOT/runtime" ]; then
    rm -f "$DOCROOT/runtime"
    ln -s "$RUNTIME_DIR" "$DOCROOT/runtime"
elif [ ! -e "$DOCROOT/runtime/core.lua" ]; then
    rm -f "$DOCROOT/runtime" 2>/dev/null || true
    # If a real directory is in the way without core.lua, replace it.
    if [ -e "$DOCROOT/runtime" ] && [ ! -L "$DOCROOT/runtime" ]; then
        rm -rf "$DOCROOT/runtime"
    fi
    ln -s "$RUNTIME_DIR" "$DOCROOT/runtime"
fi

EXTRA=()
if [ "$DEBUG" = "1" ]; then EXTRA+=(--debug); fi
if [ "$SANDBOX_UNRESTRICTED" = "1" ]; then EXTRA+=(--sandbox-unrestricted); fi
if [ -n "$WS_TOKEN" ]; then EXTRA+=(--ws-token "$WS_TOKEN"); fi
if [ -n "$PURGE_TOKEN" ]; then EXTRA+=(--purge-token "$PURGE_TOKEN"); fi

if [ "$SANDBOX_UNRESTRICTED" = "1" ]; then
    SANDBOX_MODE="unrestricted (--sandbox-unrestricted)"
else
    SANDBOX_MODE="constrained (default)"
fi

echo "luan_mac CLI (temp workspace)"
echo "  LUAN_BIN:       $LUAN_BIN"
echo "  RUNTIME_DIR:    $RUNTIME_DIR"
echo "  DOCROOT:        $DOCROOT"
echo "  BASE_URL:       http://${HOST}:${PORT}"
echo "  SANDBOX:        $SANDBOX_MODE"
echo "  ACTIVATION_KEY: $ACTIVATION_KEY"
echo "  JWT_SECRET:     $JWT_SECRET"
echo ""

run_cmd=(
    "$LUAN_BIN"
    --document-root "$DOCROOT"
    --host "$HOST"
    --port "$PORT"
    --workers "$WORKERS"
    --jwt-secret "$JWT_SECRET"
    --activation-key "$ACTIVATION_KEY"
)
# append optional flags
if [ ${#EXTRA[@]} -gt 0 ]; then
    run_cmd+=("${EXTRA[@]}")
fi

# Print full executable command (shell-quoted) for copy/paste & crash debugging.
cmd_line=""
for _arg in "${run_cmd[@]}"; do
    if [ -z "$cmd_line" ]; then
        cmd_line="$(printf '%q' "$_arg")"
    else
        cmd_line+=" $(printf '%q' "$_arg")"
    fi
done
echo "  CMD:            $cmd_line"
echo ""

if [ "$BG" = "1" ]; then
    "${run_cmd[@]}" >"$DOCROOT/cli.stdout" 2>"$DOCROOT/cli.stderr" &
    echo $! >"$DOCROOT/cli.pid"
    echo "started in background"
    echo "  PID=$(cat "$DOCROOT/cli.pid")"
    echo "  logs: $DOCROOT/cli.stdout / $DOCROOT/cli.stderr"
    echo "  stop: kill \$(cat \"$DOCROOT/cli.pid\")"
    for _ in $(seq 1 60); do
        if ! kill -0 "$(cat "$DOCROOT/cli.pid")" 2>/dev/null; then
            echo "error: process exited early; tail stderr:" >&2
            tail -n 40 "$DOCROOT/cli.stderr" >&2 || true
            exit 1
        fi
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOST}:${PORT}/" 2>/dev/null || echo 000)
        if echo "$code" | grep -qE '^[2345]'; then
            echo "  ready (HTTP $code)"
            # machine-readable line for scripts
            echo "DOCROOT=$DOCROOT"
            echo "BASE_URL=http://${HOST}:${PORT}"
            exit 0
        fi
        sleep 0.25
    done
    echo "warning: still starting; check logs under $DOCROOT" >&2
    echo "DOCROOT=$DOCROOT"
    echo "BASE_URL=http://${HOST}:${PORT}"
    exit 0
fi

echo "foreground (Ctrl+C to stop). DOCROOT kept at: $DOCROOT"
echo ""
exec "${run_cmd[@]}"
