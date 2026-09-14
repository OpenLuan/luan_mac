#!/usr/bin/env bash
# Build and start the localhost-only test app with the test-only exit handle.
# Paths are supplied by the caller so this script is safe to commit and reuse.
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "error: start_test_app.sh accepts configuration through environment variables, not positional arguments" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${TEST_RUNTIME:?Set TEST_RUNTIME to the deployed runtime path}"
: "${TEST_DOCROOT:?Set TEST_DOCROOT to the test document root}"
: "${DERIVED_DATA:?Set DERIVED_DATA to the Xcode DerivedData path}"
TEST_PORT="${TEST_PORT:-8081}"
TEST_HOST="${TEST_HOST:-127.0.0.1}"
export ACTIVATION_KEY="${ACTIVATION_KEY:-testkey123}"
export JWT_SECRET="${JWT_SECRET:-test_jwt_secret_key_for_ci}"

if [ "${TEST_HOST:-127.0.0.1}" != "127.0.0.1" ]; then
    echo "error: test app must bind to 127.0.0.1" >&2
    exit 1
fi

if [ -f "$TEST_DOCROOT/cli.pid" ]; then
    old_pid="$(cat "$TEST_DOCROOT/cli.pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
        for _ in $(seq 1 40); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "error: old test app did not stop (pid $old_pid)" >&2
            exit 1
        fi
    fi
    rm -f "$TEST_DOCROOT/cli.pid"
fi

RESET_TEST_DOCROOT="${RESET_TEST_DOCROOT:-0}"
if [ "$RESET_TEST_DOCROOT" = "1" ]; then
    case "$TEST_DOCROOT" in
        ""|"/"|"$PROJECT_ROOT"|"$TEST_RUNTIME")
            echo "error: refusing to reset unsafe TEST_DOCROOT: $TEST_DOCROOT" >&2
            exit 1
            ;;
        */qa|*/qa/)
            echo "error: refusing to reset persistent qa TEST_DOCROOT: $TEST_DOCROOT" >&2
            exit 1
            ;;
    esac
    if [ -L "$TEST_DOCROOT" ]; then
        echo "error: refusing to reset symlink TEST_DOCROOT: $TEST_DOCROOT" >&2
        exit 1
    fi
    mkdir -p "$TEST_DOCROOT"
    for entry in "$TEST_DOCROOT"/* "$TEST_DOCROOT"/.[!.]* "$TEST_DOCROOT"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        rm -rf "$entry"
    done
else
    mkdir -p "$TEST_DOCROOT"
fi

export LUAN_TEST_ENV=1
export BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
export SERVICE_PORT="$TEST_PORT"
export FILE_SCAN_TEST_ROOT="${FILE_SCAN_TEST_ROOT:-$TEST_DOCROOT/test-fixtures/file_scan_symlink}"
# The luan CLI target has no NativeChromeMCP (app target only); never let a
# inherited NATIVE_CHROME_MCP_ENABLED=1 make the test env try to reach the
# app's native MCP (wrong token -> 401). The chrome-devtools client falls back
# to the direct CDP path in this env.
export NATIVE_CHROME_MCP_ENABLED=0
export TEST_ADMIN_USER="${TEST_ADMIN_USER:-}"
export TEST_ADMIN_PASSWORD="${TEST_ADMIN_PASSWORD:-}"
export TEST_USER_USER="${TEST_USER_USER:-}"
export TEST_USER_PASSWORD="${TEST_USER_PASSWORD:-}"
# Lua os.getenv returns an empty string as truthy; make legacy suites that
# prefer TEST_EXISTING_* fall back to the freshly initialized admin account.
if [ -z "${TEST_EXISTING_USER:-}" ]; then TEST_EXISTING_USER="$TEST_ADMIN_USER"; fi
if [ -z "${TEST_EXISTING_PASSWORD:-}" ]; then TEST_EXISTING_PASSWORD="$TEST_ADMIN_PASSWORD"; fi
export TEST_EXISTING_USER TEST_EXISTING_PASSWORD

if [ "$TEST_RUNTIME" = "$PROJECT_ROOT/runtime" ]; then
    # TEST_DOCROOT/runtime may be a symlink to this build output.
    # Build in place without asking build_runtime.sh to redeploy over itself.
    "$SCRIPT_DIR/build_runtime.sh"
else
    DEPLOY_RUNTIME="$TEST_RUNTIME" "$SCRIPT_DIR/build_runtime.sh"
fi

export RUNTIME_DIR="$TEST_RUNTIME"
export DOCROOT="$TEST_DOCROOT"
export HOST="$TEST_HOST"
export PORT="$TEST_PORT"
export DERIVED_DATA

"$SCRIPT_DIR/run_cli_temp.sh" --bg --docroot "$TEST_DOCROOT" --port "$TEST_PORT" --host "$TEST_HOST"

register_test_admin() {
    local username="$1" password="$2" code login_code
    [ -n "$username" ] && [ -n "$password" ] || return 0
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "{\"username\":\"$username\",\"password\":\"$password\",\"activation_key\":\"$ACTIVATION_KEY\"}" \
        "$BASE_URL/_api/auth/register" || echo 000)"
    case "$code" in
        201|409) echo "  test admin account ready: $username" ;;
        403)
            login_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
                -H "Content-Type: application/json; charset=utf-8" \
                -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
                "$BASE_URL/_api/auth/login" || echo 000)"
            if [ "$login_code" = "200" ]; then
                echo "  test admin account ready: $username"
            else
                echo "error: existing test admin account cannot login: $username (HTTP $login_code)" >&2
                exit 1
            fi
            ;;
        *) echo "error: failed to initialize test admin account $username (HTTP $code)" >&2; exit 1 ;;
    esac
}

register_test_user() {
    local username="$1" password="$2" admin_user="$3" admin_password="$4" login_body token code
    [ -n "$username" ] && [ -n "$password" ] || return 0
    login_body="$(curl -sS -X POST -H "Content-Type: application/json; charset=utf-8" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_password\"}" \
        "$BASE_URL/_api/auth/login")"
    token="$(printf '%s' "$login_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')"
    [ -n "$token" ] || { echo "error: failed to login test admin for user initialization" >&2; exit 1; }
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Cookie: luan_token=$token" \
        -d "{\"username\":\"$username\",\"password\":\"$password\",\"role\":\"user\"}" \
        "$BASE_URL/_api/users" || echo 000)"
    case "$code" in
        201|409) echo "  test user account ready: $username" ;;
        *) echo "error: failed to initialize test user account $username (HTTP $code)" >&2; exit 1 ;;
    esac
}

if [ "$RESET_TEST_DOCROOT" = "1" ] && { [ -z "$TEST_ADMIN_USER" ] || [ -z "$TEST_ADMIN_PASSWORD" ]; }; then
    echo "error: fresh test docroot requires TEST_ADMIN_USER and TEST_ADMIN_PASSWORD" >&2
    exit 1
fi
register_test_admin "$TEST_ADMIN_USER" "$TEST_ADMIN_PASSWORD"
register_test_user "$TEST_USER_USER" "$TEST_USER_PASSWORD" "$TEST_ADMIN_USER" "$TEST_ADMIN_PASSWORD"
