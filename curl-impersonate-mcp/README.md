# curl-impersonate-mcp

A minimal stdio MCP server that wraps `libcurl-impersonate` for browser
TLS/HTTP2 fingerprinting. It runs as a separate subprocess of the main
`luan` binary so that the Apple-side `CBB_add_space` /
`ossl_chain_get_der` leak observed in `Curl_vtls_apple_verify` cannot
accumulate inside the long-lived main process.

## Why a separate process?

`libcurl-impersonate` builds on top of a patched BoringSSL + libcurl and
on macOS the verify path goes through `Curl_vtls_apple_verify`, which
pulls in Apple's SecTrust evaluation. Instruments shows a steady leak in
`CBB_add_space` under that call stack. By splitting fingerprinted
requests into a short-lived subprocess the leak is bounded to the
subprocess lifetime, and the main binary is free to link against a
clean stock libcurl + OpenSSL stack.

## Protocol

Standard MCP stdio transport: newline-delimited JSON-RPC 2.0 on stdin
(requests) and stdout (responses). stderr is reserved for diagnostics.

### `initialize`

Standard MCP handshake. Returns server info and advertised capabilities.

### `tools/list`

Returns the single tool `fetch`.

### `tools/call` with `name = "fetch"`

Arguments:

| field              | type    | required | description |
| ------------------ | ------- | -------- | ----------- |
| `url`              | string  | yes      | request URL |
| `method`           | string  | no       | `GET` (default), `POST`, `PUT`, `DELETE`, `HEAD` |
| `headers`          | object  | no       | map of header name → value |
| `body`             | string  | no       | request body (text or base64, see `body_encoding`) |
| `body_encoding`    | string  | no       | `text` (default) or `base64` |
| `impersonate`      | string  | no       | fingerprint target, e.g. `chrome150`, `chrome120`, `firefox133` |
| `timeout`          | number  | no       | total timeout in seconds (default 60; max 300) |
| `verify_peer`      | bool    | no       | TLS peer verification (default `true`) |
| `verify_host`      | bool    | no       | TLS host verification (default `true`) |
| `follow_redirects` | bool    | no       | follow 3xx (default `false`; libcurl handles internally) |
| `max_redirects`    | number  | no       | redirect cap when `follow_redirects` (default 5) |

Response content (MCP `content` array with a single `text` item that
contains JSON):

```json
{
  "status": 200,
  "headers": {"content-type": "application/json", ...},
  "body": "...",
  "body_encoding": "text" | "base64",
  "total_time": 0.123,
  "error": null
}
```

- `body` is `text` when the response passes a UTF-8 validity check and
  does not contain NUL bytes; otherwise it is base64-encoded and
  `body_encoding = "base64"`.
- Responses larger than 16 MiB are truncated with `error = "body-too-large"`.
- Transport-level failures (DNS/TLS/connect) set `status = 0` and
  populate `error` with the libcurl error string.

## Lifecycle

The main `luan` process starts and keeps the subprocess alive via
`mcp_client.lua` (newline JSON-RPC). To cap leak accumulation inside
this subprocess, the server self-exits in two conditions:

1. after `MAX_CALLS` successful calls (default 100), or
2. when its RSS passes `MAX_RSS_MB` (default 256 MiB).

The main-side `mcp_client` observes the EOF, marks the entry
disconnected, and the next `fetch` call lazily spawns a fresh instance.

## Build

Built as an Xcode target `curl-impersonate-mcp` alongside `LuanMac` and
`luan`. The LuanMac post-build phase copies the resulting binary into
`Contents/MacOS/curl-impersonate-mcp`. It links against:

- `Frameworks/libcurl-impersonate.xcframework` (embedded dylib; the
  main binary does NOT link this)
- `Frameworks/libssl.xcframework` + `Frameworks/libcrypto.xcframework`
  (same OpenSSL as main binary; static .a)

## Files

- `main.c` — stdio JSON-RPC loop, MCP handshake, `fetch` dispatcher
- `json.c` / `json.h` — minimal JSON parser/encoder (no third-party
  dependency; stays under 400 LoC)
- `base64.c` / `base64.h` — RFC 4648 base64 encoder (decoder for
  request body only)
- `README.md` — this file
