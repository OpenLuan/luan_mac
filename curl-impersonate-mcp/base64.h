/* base64.h — minimal RFC 4648 base64 for curl-impersonate-mcp.
 *
 * Only "standard" alphabet is supported; no URL-safe variant, no line wrapping.
 * The encoder writes into a caller-provided buffer (`out`) whose size must be
 * at least `base64_encoded_size(len)`; the decoder is forgiving of embedded
 * whitespace but rejects any other non-alphabet byte. */

#ifndef CURL_IMPERSONATE_MCP_BASE64_H
#define CURL_IMPERSONATE_MCP_BASE64_H

#include <stddef.h>

/* Return the exact number of output bytes required to encode `len` input
 * bytes, excluding any trailing NUL. */
size_t base64_encoded_size(size_t len);

/* Encode `in[0..len)` into `out`. `out` must point to at least
 * base64_encoded_size(len)+1 bytes; a trailing NUL is written. Returns the
 * number of bytes written (not counting the NUL). */
size_t base64_encode(const unsigned char *in, size_t len, char *out);

/* Decode `in[0..len)` (NUL-terminated or not; any whitespace is skipped).
 * Writes at most `out_cap` bytes to `out`. On success returns the number of
 * bytes decoded; on malformed input returns (size_t)-1. */
size_t base64_decode(const char *in, size_t len, unsigned char *out, size_t out_cap);

#endif
