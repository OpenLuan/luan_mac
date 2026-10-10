/* main.c — curl-impersonate-mcp
 *
 * A minimal stdio MCP server (JSON-RPC 2.0) that wraps libcurl-impersonate's
 * synchronous `curl_easy_perform` interface. See README.md for the protocol
 * details and the rationale for running this as a separate process.
 *
 * Transport
 *   - stdin:  newline-delimited JSON-RPC 2.0 requests
 *   - stdout: newline-delimited JSON-RPC 2.0 responses
 *   - stderr: free-form diagnostics (captured by mcp_client.lua)
 *
 * Lifecycle
 *   The server self-exits after MAX_CALLS successful fetches or when its
 *   RSS passes MAX_RSS_MB, whichever comes first. The parent (mcp_client.lua)
 *   notices the EOF and lazily respawns on the next request.
 */

#include "json.h"
#include "base64.h"

#include <curl/curl.h>

/* curl_easy_impersonate is only declared in libcurl-impersonate's own
 * curl/easy.h, which we deliberately do NOT include here (the vanilla
 * curl headers are what Xcode copies into ${BUILT_PRODUCTS_DIR}/include/
 * for the LuanMac target). The symbol itself is resolved at link time
 * against -lcurl-impersonate.4 (OTHER_LDFLAGS). ABI is stable in the
 * 1.x series. */
extern CURLcode curl_easy_impersonate(CURL *curl, const char *target,
                                      int default_headers);

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/resource.h>

#if defined(__APPLE__)
#  include <mach/mach.h>
#endif

/* ---- lifecycle caps -------------------------------------------------- */

static const long  MAX_CALLS       = 100;
static const long  MAX_RSS_BYTES   = 256L * 1024L * 1024L;
static const long  MAX_RESP_BYTES  = 16L * 1024L * 1024L;
static const long  MAX_TIMEOUT_SEC = 300;

static long g_calls_handled = 0;

static long self_rss_bytes(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (long)info.resident_size;
    }
    return 0;
#else
    struct rusage r;
    if (getrusage(RUSAGE_SELF, &r) == 0) {
        /* ru_maxrss is in KB on Linux. */
        return (long)r.ru_maxrss * 1024L;
    }
    return 0;
#endif
}

static int should_exit(void) {
    if (g_calls_handled >= MAX_CALLS) return 1;
    long rss = self_rss_bytes();
    if (rss > 0 && rss > MAX_RSS_BYTES) return 1;
    return 0;
}

/* ---- stdio line reader ---------------------------------------------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} line_buf_t;

static int line_buf_grow(line_buf_t *lb, size_t need) {
    if (need <= lb->cap) return 0;
    size_t ncap = lb->cap ? lb->cap : 1024;
    while (ncap < need) ncap *= 2;
    char *nb = (char *)realloc(lb->buf, ncap);
    if (!nb) return -1;
    lb->buf = nb;
    lb->cap = ncap;
    return 0;
}

/* Read one newline-delimited frame from stdin. Returns 1 on success, 0 on
 * EOF, -1 on error. The returned bytes do NOT include the newline, but a
 * trailing NUL is written for convenience. */
static int read_one_line(line_buf_t *lb) {
    lb->len = 0;
    for (;;) {
        int c = fgetc(stdin);
        if (c == EOF) {
            if (lb->len == 0) return 0;
            /* Final frame without newline — still return it. */
            if (line_buf_grow(lb, lb->len + 1) < 0) return -1;
            lb->buf[lb->len] = '\0';
            return 1;
        }
        if (c == '\n') {
            if (line_buf_grow(lb, lb->len + 1) < 0) return -1;
            lb->buf[lb->len] = '\0';
            return 1;
        }
        if (line_buf_grow(lb, lb->len + 2) < 0) return -1;
        lb->buf[lb->len++] = (char)c;
    }
}

/* ---- JSON-RPC helpers ----------------------------------------------- */

static void emit_response(json_value_t *msg) {
    size_t n = 0;
    char *out = json_encode(msg, &n);
    if (!out) {
        fprintf(stderr, "[curl-impersonate-mcp] json_encode failed\n");
        return;
    }
    fwrite(out, 1, n, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    free(out);
}

/* Build a bare JSON-RPC skeleton with "jsonrpc":"2.0" and (optionally) id.
 * On OOM returns NULL — caller should abort the response. */
static json_value_t *rpc_skeleton(const json_value_t *id) {
    json_value_t *msg = json_new_object();
    if (!msg) return NULL;
    if (json_object_set(msg, "jsonrpc", 7, json_new_string("2.0", 3)) < 0) goto oom;
    if (id) {
        /* Clone id (string or number). */
        json_value_t *id_copy = NULL;
        if (id->type == JSON_STRING) {
            id_copy = json_new_string(id->str ? id->str : "", id->str_len);
        } else if (id->type == JSON_NUMBER) {
            id_copy = json_new_number(id->num);
        } else if (id->type == JSON_NULL) {
            id_copy = json_new_null();
        }
        if (id_copy && json_object_set(msg, "id", 2, id_copy) < 0) goto oom;
    }
    return msg;
oom:
    json_free(msg);
    return NULL;
}

static void send_error(const json_value_t *id, int code, const char *message) {
    json_value_t *msg = rpc_skeleton(id);
    if (!msg) return;
    json_value_t *err = json_new_object();
    if (!err) { json_free(msg); return; }
    json_object_set(err, "code", 4, json_new_number((double)code));
    json_object_set(err, "message", 7, json_new_string(message, strlen(message)));
    json_object_set(msg, "error", 5, err);
    emit_response(msg);
    json_free(msg);
}

static void send_result(const json_value_t *id, json_value_t *result) {
    json_value_t *msg = rpc_skeleton(id);
    if (!msg) { json_free(result); return; }
    json_object_set(msg, "result", 6, result);
    emit_response(msg);
    json_free(msg);
}

/* ---- fetch ---------------------------------------------------------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
    int overflow;
} byte_buf_t;

static size_t curl_write_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    byte_buf_t *b = (byte_buf_t *)ud;
    size_t n = size * nmemb;
    if (b->overflow) return n;  /* keep draining to avoid curl error */
    if (b->len + n > (size_t)MAX_RESP_BYTES) {
        b->overflow = 1;
        return n;
    }
    if (b->len + n > b->cap) {
        size_t ncap = b->cap ? b->cap : 4096;
        while (ncap < b->len + n) ncap *= 2;
        char *nb = (char *)realloc(b->buf, ncap);
        if (!nb) { b->overflow = 1; return n; }
        b->buf = nb;
        b->cap = ncap;
    }
    memcpy(b->buf + b->len, ptr, n);
    b->len += n;
    return n;
}

/* UTF-8 validity: no embedded NUL and well-formed sequences. */
static int is_utf8_textual(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = s[i];
        if (c == 0) return 0;
        if (c < 0x80) { i++; continue; }
        int need;
        if ((c & 0xE0) == 0xC0) need = 1;
        else if ((c & 0xF0) == 0xE0) need = 2;
        else if ((c & 0xF8) == 0xF0) need = 3;
        else return 0;
        if (i + 1 + need > n) return 0;
        for (int k = 1; k <= need; k++) {
            if ((s[i + k] & 0xC0) != 0x80) return 0;
        }
        i += 1 + need;
    }
    return 1;
}

/* Parse one header line "Name: Value\r\n" and insert into `headers`. */
static void collect_header(byte_buf_t *raw, const char *line, size_t n) {
    /* Keep the raw bytes so parse_headers can read them later. */
    size_t need = raw->len + n;
    if (need > raw->cap) {
        size_t ncap = raw->cap ? raw->cap : 1024;
        while (ncap < need) ncap *= 2;
        char *nb = (char *)realloc(raw->buf, ncap);
        if (!nb) return;
        raw->buf = nb;
        raw->cap = ncap;
    }
    memcpy(raw->buf + raw->len, line, n);
    raw->len = need;
}

static size_t curl_header_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    byte_buf_t *b = (byte_buf_t *)ud;
    size_t n = size * nmemb;
    collect_header(b, ptr, n);
    return n;
}

/* Split accumulated raw headers (possibly containing multiple response
 * groups for redirects) into {name->value} using the final group. Returns a
 * JSON object (never NULL unless OOM). */
static json_value_t *parse_headers(const char *raw, size_t raw_len) {
    json_value_t *obj = json_new_object();
    if (!obj) return NULL;
    if (!raw || raw_len == 0) return obj;

    /* Find the last blank-line-separated group. */
    const char *start = raw;
    const char *last_start = raw;
    const char *end = raw + raw_len;
    for (const char *p = raw; p + 3 < end; p++) {
        if (p[0] == '\r' && p[1] == '\n' && p[2] == '\r' && p[3] == '\n') {
            /* Everything up to p+3 is one block (ending status + headers +
             * blank line). The next block starts at p+4. */
            if (p + 4 < end) last_start = p + 4;
            p += 3;
        }
    }
    start = last_start;

    /* Walk CRLF-separated lines. First line is the status line; skip it. */
    const char *line = start;
    int first = 1;
    while (line < end) {
        const char *lf = memchr(line, '\n', (size_t)(end - line));
        const char *stop = lf ? lf : end;
        size_t len = (size_t)(stop - line);
        /* Trim trailing CR. */
        if (len > 0 && line[len - 1] == '\r') len--;
        if (len == 0) { if (lf) line = lf + 1; else break; continue; }
        if (first) { first = 0; if (lf) line = lf + 1; else break; continue; }
        const char *colon = memchr(line, ':', len);
        if (colon) {
            size_t klen = (size_t)(colon - line);
            const char *vstart = colon + 1;
            size_t vlen = len - klen - 1;
            while (vlen > 0 && (*vstart == ' ' || *vstart == '\t')) { vstart++; vlen--; }
            if (klen > 0) {
                json_value_t *jv = json_new_string(vstart, vlen);
                if (jv) json_object_set(obj, line, klen, jv);
            }
        }
        if (!lf) break;
        line = lf + 1;
    }
    return obj;
}

typedef struct {
    const char *method;
    const char *url;
    const char *target;
    const char *body;
    size_t body_len;
    double timeout;
    int verify_peer;
    int verify_host;
    int default_headers;
    int follow_redirects;
    long max_redirects;
    struct curl_slist *req_headers;
} fetch_args_t;

static int tool_fetch(const json_value_t *params, json_value_t **result_out,
                      char *errbuf, size_t errbuf_cap) {
    *result_out = NULL;
    json_value_t *args_obj = json_object_get(params, "arguments");
    if (!args_obj || args_obj->type != JSON_OBJECT) {
        snprintf(errbuf, errbuf_cap, "arguments object required");
        return -1;
    }

    fetch_args_t fa;
    memset(&fa, 0, sizeof(fa));
    fa.method = "GET";
    fa.timeout = 60.0;
    fa.verify_peer = 1;
    fa.verify_host = 1;
    fa.default_headers = 1;
    fa.follow_redirects = 0;
    fa.max_redirects = 5;

    size_t slen = 0;
    const char *s;
    s = json_as_string(json_object_get(args_obj, "url"), &slen);
    if (!s || slen == 0) {
        snprintf(errbuf, errbuf_cap, "url is required");
        return -1;
    }
    fa.url = s;
    s = json_as_string(json_object_get(args_obj, "method"), &slen);
    if (s && slen > 0) fa.method = s;
    /* Fingerprint aliases. */
    s = json_as_string(json_object_get(args_obj, "impersonate"), &slen);
    if (!s) s = json_as_string(json_object_get(args_obj, "target"), &slen);
    if (!s) s = json_as_string(json_object_get(args_obj, "fingerprint"), &slen);
    fa.target = s;

    /* Body: text (as-is) or base64 (decoded into a scratch buffer). */
    char *body_scratch = NULL;
    s = json_as_string(json_object_get(args_obj, "body"), &slen);
    if (s) {
        const char *enc = json_as_string(json_object_get(args_obj, "body_encoding"), NULL);
        if (enc && strcmp(enc, "base64") == 0) {
            body_scratch = (char *)malloc(slen);
            if (!body_scratch) {
                snprintf(errbuf, errbuf_cap, "oom body");
                return -1;
            }
            size_t out_n = base64_decode(s, slen, (unsigned char *)body_scratch, slen);
            if (out_n == (size_t)-1) {
                free(body_scratch);
                snprintf(errbuf, errbuf_cap, "invalid base64 body");
                return -1;
            }
            fa.body = body_scratch;
            fa.body_len = out_n;
        } else {
            fa.body = s;
            fa.body_len = slen;
        }
    }

    fa.timeout = json_as_number(json_object_get(args_obj, "timeout"), fa.timeout);
    if (fa.timeout < 1.0) fa.timeout = 1.0;
    if (fa.timeout > (double)MAX_TIMEOUT_SEC) fa.timeout = (double)MAX_TIMEOUT_SEC;
    fa.verify_peer = json_as_bool(json_object_get(args_obj, "verify_peer"), fa.verify_peer);
    fa.verify_host = json_as_bool(json_object_get(args_obj, "verify_host"), fa.verify_host);
    /* ssl_verify is the shortcut Lua uses. */
    json_value_t *sv = json_object_get(args_obj, "ssl_verify");
    if (sv && sv->type == JSON_BOOL) {
        fa.verify_peer = sv->bval;
        fa.verify_host = sv->bval;
    }
    fa.follow_redirects = json_as_bool(json_object_get(args_obj, "follow_redirects"), 0);
    double mr = json_as_number(json_object_get(args_obj, "max_redirects"), 5.0);
    if (mr < 0) mr = 0;
    if (mr > 50) mr = 50;
    fa.max_redirects = (long)mr;
    fa.default_headers = json_as_bool(json_object_get(args_obj, "default_headers"), 1);

    CURL *easy = curl_easy_init();
    if (!easy) {
        free(body_scratch);
        snprintf(errbuf, errbuf_cap, "curl_easy_init failed");
        return -1;
    }
    if (curl_easy_impersonate(easy, fa.target ? fa.target : "chrome120",
                              fa.default_headers) != CURLE_OK) {
        curl_easy_cleanup(easy);
        free(body_scratch);
        snprintf(errbuf, errbuf_cap, "curl_easy_impersonate failed");
        return -1;
    }

    char errstr[CURL_ERROR_SIZE];
    errstr[0] = '\0';
    byte_buf_t body_b = { NULL, 0, 0, 0 };
    byte_buf_t hdr_b  = { NULL, 0, 0, 0 };

    curl_easy_setopt(easy, CURLOPT_URL, fa.url);
    curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, fa.method);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, (long)(fa.timeout * 1000.0));
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, (long)(fa.timeout * 1000.0));
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, fa.verify_peer ? 1L : 0L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, fa.verify_host ? 2L : 0L);
    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, errstr);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &body_b);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, curl_header_cb);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &hdr_b);
    if (fa.follow_redirects) {
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(easy, CURLOPT_MAXREDIRS, fa.max_redirects);
    } else {
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    }

    if (strcmp(fa.method, "HEAD") == 0) {
        curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
    } else if (fa.body) {
        curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)fa.body_len);
        curl_easy_setopt(easy, CURLOPT_COPYPOSTFIELDS, fa.body);
    }

    /* Request headers. */
    json_value_t *hdrs = json_object_get(args_obj, "headers");
    if (hdrs && hdrs->type == JSON_OBJECT) {
        for (json_value_t *c = hdrs->first; c; c = c->next) {
            if (c->type != JSON_STRING) continue;
            size_t klen = c->key_len;
            size_t vlen = c->str_len;
            size_t need = klen + 2 + vlen + 1;
            char *line = (char *)malloc(need);
            if (!line) continue;
            snprintf(line, need, "%.*s: %.*s", (int)klen, c->key, (int)vlen, c->str);
            fa.req_headers = curl_slist_append(fa.req_headers, line);
            free(line);
        }
        if (fa.req_headers) curl_easy_setopt(easy, CURLOPT_HTTPHEADER, fa.req_headers);
    }

    CURLcode rc = curl_easy_perform(easy);

    long status = 0;
    double total_time = 0.0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(easy, CURLINFO_TOTAL_TIME, &total_time);

    /* Build result object. */
    json_value_t *obj = json_new_object();
    if (!obj) {
        curl_slist_free_all(fa.req_headers);
        curl_easy_cleanup(easy);
        free(body_b.buf);
        free(hdr_b.buf);
        free(body_scratch);
        snprintf(errbuf, errbuf_cap, "oom result");
        return -1;
    }
    json_object_set(obj, "status", 6, json_new_number((double)status));
    json_object_set(obj, "total_time", 10, json_new_number(total_time));
    if (rc != CURLE_OK) {
        const char *msg = errstr[0] ? errstr : curl_easy_strerror(rc);
        json_object_set(obj, "error", 5, json_new_string(msg, strlen(msg)));
    } else {
        json_object_set(obj, "error", 5, json_new_null());
    }

    json_value_t *hdr_obj = parse_headers(hdr_b.buf, hdr_b.len);
    if (hdr_obj) json_object_set(obj, "headers", 7, hdr_obj);

    if (body_b.overflow) {
        /* Replace error with explicit body-too-large; keep partial body out. */
        json_object_set(obj, "body", 4, json_new_string("", 0));
        json_object_set(obj, "body_encoding", 13, json_new_string("text", 4));
        json_object_set(obj, "error", 5,
                        json_new_string("body-too-large", 14));
        json_object_set(obj, "body_truncated", 14, json_new_bool(1));
    } else if (body_b.len == 0) {
        json_object_set(obj, "body", 4, json_new_string("", 0));
        json_object_set(obj, "body_encoding", 13, json_new_string("text", 4));
    } else if (is_utf8_textual((const unsigned char *)body_b.buf, body_b.len)) {
        json_object_set(obj, "body", 4, json_new_string(body_b.buf, body_b.len));
        json_object_set(obj, "body_encoding", 13, json_new_string("text", 4));
    } else {
        size_t enc_cap = base64_encoded_size(body_b.len);
        char *enc = (char *)malloc(enc_cap + 1);
        if (enc) {
            size_t enc_n = base64_encode((const unsigned char *)body_b.buf, body_b.len, enc);
            json_object_set(obj, "body", 4, json_new_string(enc, enc_n));
            json_object_set(obj, "body_encoding", 13, json_new_string("base64", 6));
            free(enc);
        } else {
            json_object_set(obj, "body", 4, json_new_string("", 0));
            json_object_set(obj, "body_encoding", 13, json_new_string("text", 4));
            json_object_set(obj, "error", 5, json_new_string("oom-base64", 10));
        }
    }

    /* Wrap into MCP content[]: array of {type:text, text:<serialized json>}. */
    size_t inner_n = 0;
    char *inner = json_encode(obj, &inner_n);
    json_free(obj);
    curl_slist_free_all(fa.req_headers);
    curl_easy_cleanup(easy);
    free(body_b.buf);
    free(hdr_b.buf);
    free(body_scratch);

    if (!inner) {
        snprintf(errbuf, errbuf_cap, "encode result");
        return -1;
    }

    json_value_t *content = json_new_array();
    json_value_t *item = json_new_object();
    if (!content || !item) {
        free(inner);
        json_free(content);
        json_free(item);
        snprintf(errbuf, errbuf_cap, "oom wrap");
        return -1;
    }
    json_object_set(item, "type", 4, json_new_string("text", 4));
    json_object_set(item, "text", 4, json_new_string(inner, inner_n));
    free(inner);
    json_array_push(content, item);

    json_value_t *result = json_new_object();
    if (!result) {
        json_free(content);
        snprintf(errbuf, errbuf_cap, "oom result wrap");
        return -1;
    }
    json_object_set(result, "content", 7, content);
    *result_out = result;
    return 0;
}

/* ---- method dispatch ------------------------------------------------ */

static json_value_t *build_tool_schema(void) {
    /* Minimal JSON Schema advertising the `fetch` tool. */
    json_value_t *schema = json_new_object();
    if (!schema) return NULL;
    json_object_set(schema, "type", 4, json_new_string("object", 6));

    json_value_t *props = json_new_object();
    json_value_t *tmp;

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("string", 6));
    json_object_set(tmp, "description", 11, json_new_string("Target URL", 10));
    json_object_set(props, "url", 3, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("string", 6));
    json_object_set(tmp, "description", 11,
                    json_new_string("HTTP method (GET/POST/PUT/DELETE/HEAD)", 38));
    json_object_set(props, "method", 6, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("object", 6));
    json_object_set(tmp, "description", 11, json_new_string("Request headers map", 19));
    json_object_set(props, "headers", 7, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("string", 6));
    json_object_set(tmp, "description", 11, json_new_string("Request body", 12));
    json_object_set(props, "body", 4, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("string", 6));
    json_object_set(tmp, "description", 11,
                    json_new_string("body encoding: text (default) or base64", 39));
    json_object_set(props, "body_encoding", 13, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("string", 6));
    json_object_set(tmp, "description", 11,
                    json_new_string("Browser impersonation target, e.g. chrome120", 44));
    json_object_set(props, "impersonate", 11, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("number", 6));
    json_object_set(tmp, "description", 11,
                    json_new_string("Timeout in seconds (default 60, max 300)", 40));
    json_object_set(props, "timeout", 7, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("boolean", 7));
    json_object_set(tmp, "description", 11,
                    json_new_string("Follow 3xx redirects (default false)", 36));
    json_object_set(props, "follow_redirects", 16, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("boolean", 7));
    json_object_set(tmp, "description", 11,
                    json_new_string("TLS peer verification (default true)", 36));
    json_object_set(props, "verify_peer", 11, tmp);

    tmp = json_new_object();
    json_object_set(tmp, "type", 4, json_new_string("boolean", 7));
    json_object_set(tmp, "description", 11,
                    json_new_string("TLS host verification (default true)", 36));
    json_object_set(props, "verify_host", 11, tmp);

    json_object_set(schema, "properties", 10, props);

    json_value_t *req = json_new_array();
    json_array_push(req, json_new_string("url", 3));
    json_object_set(schema, "required", 8, req);
    return schema;
}

static void handle_initialize(const json_value_t *id) {
    json_value_t *result = json_new_object();
    if (!result) { send_error(id, -32603, "oom"); return; }
    json_object_set(result, "protocolVersion", 15, json_new_string("2024-11-05", 10));

    json_value_t *caps = json_new_object();
    json_value_t *tools_cap = json_new_object();
    json_object_set(caps, "tools", 5, tools_cap);
    json_object_set(result, "capabilities", 12, caps);

    json_value_t *info = json_new_object();
    json_object_set(info, "name", 4, json_new_string("curl-impersonate-mcp", 20));
    json_object_set(info, "version", 7, json_new_string("1.0.0", 5));
    json_object_set(result, "serverInfo", 10, info);

    send_result(id, result);
}

static void handle_tools_list(const json_value_t *id) {
    json_value_t *result = json_new_object();
    if (!result) { send_error(id, -32603, "oom"); return; }
    json_value_t *arr = json_new_array();
    json_value_t *tool = json_new_object();
    json_object_set(tool, "name", 4, json_new_string("fetch", 5));
    json_object_set(tool, "description", 11,
                    json_new_string(
                        "Perform an HTTP(S) request through libcurl-impersonate "
                        "(browser TLS fingerprinting). Runs in a subprocess so "
                        "upstream leaks cannot grow in the main luan process.",
                        167));
    json_object_set(tool, "inputSchema", 11, build_tool_schema());
    json_array_push(arr, tool);
    json_object_set(result, "tools", 5, arr);
    send_result(id, result);
}

static void handle_tools_call(const json_value_t *id, const json_value_t *params) {
    const char *name = json_as_string(json_object_get(params, "name"), NULL);
    if (!name || strcmp(name, "fetch") != 0) {
        send_error(id, -32601, "unknown tool");
        return;
    }
    char errbuf[256];
    json_value_t *result = NULL;
    if (tool_fetch(params, &result, errbuf, sizeof(errbuf)) < 0) {
        send_error(id, -32603, errbuf);
        return;
    }
    g_calls_handled++;
    send_result(id, result);
}

/* Dispatch a single parsed JSON-RPC message. Returns 1 to continue, 0 to
 * exit (e.g. on `shutdown` notification). */
static int dispatch(const json_value_t *msg) {
    const json_value_t *id = json_object_get(msg, "id");
    const char *method = json_as_string(json_object_get(msg, "method"), NULL);
    if (!method) {
        /* Ignore responses to our own notifications (we send none). */
        return 1;
    }
    const json_value_t *params = json_object_get(msg, "params");

    if (strcmp(method, "initialize") == 0) {
        if (id) handle_initialize(id);
        return 1;
    }
    if (strcmp(method, "notifications/initialized") == 0) {
        /* Notification — no response. */
        return 1;
    }
    if (strcmp(method, "tools/list") == 0) {
        if (id) handle_tools_list(id);
        return 1;
    }
    if (strcmp(method, "tools/call") == 0) {
        if (id) handle_tools_call(id, params);
        return 1;
    }
    if (strcmp(method, "shutdown") == 0 || strcmp(method, "exit") == 0) {
        if (id) {
            json_value_t *result = json_new_object();
            send_result(id, result);
        }
        return 0;
    }
    if (id) send_error(id, -32601, "method not found");
    return 1;
}

/* ---- main ----------------------------------------------------------- */

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    /* Ignore SIGPIPE. Two independent write paths can hit a dead peer:
     *
     *   1) stdout → mcp_client.lua. If the parent luan process exits
     *      first, our next JSON-RPC reply write would die with SIGPIPE
     *      and we would never run curl_global_cleanup. (The parent
     *      restarts us on demand anyway, but a clean teardown is nicer
     *      than SIGPIPE for debugging.)
     *   2) libcurl → upstream TCP socket. On macOS libcurl does not set
     *      SO_NOSIGPIPE on its sockets and `send()` has no
     *      MSG_NOSIGNAL, so any upstream RST during an in-flight
     *      request would terminate this subprocess with rc=141. We
     *      must surface the EPIPE back to libcurl so it can report the
     *      transport error to the caller instead.
     *
     * Same reasoning as LuanCLI/main.swift and luafan2/src/main.c; the
     * ignore stays for the lifetime of the process. */
    signal(SIGPIPE, SIG_IGN);

    /* Line-buffered stdout so each JSON-RPC response is flushed promptly. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    /* Fully-buffered stderr is fine; mcp_client reads it as a byte stream. */

    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        fprintf(stderr, "[curl-impersonate-mcp] curl_global_init failed\n");
        return 1;
    }

    line_buf_t lb = { NULL, 0, 0 };
    for (;;) {
        int r = read_one_line(&lb);
        if (r == 0) break;      /* EOF */
        if (r < 0) {
            fprintf(stderr, "[curl-impersonate-mcp] stdin read error\n");
            break;
        }
        if (lb.len == 0) continue;
        const char *err = NULL;
        json_value_t *msg = json_parse(lb.buf, lb.len, &err);
        if (!msg) {
            fprintf(stderr, "[curl-impersonate-mcp] parse error: %s\n",
                    err ? err : "?");
            /* Protocol-level error — try to respond without an id. */
            send_error(NULL, -32700, err ? err : "parse error");
            continue;
        }
        int keep_going = dispatch(msg);
        json_free(msg);
        if (!keep_going) break;
        if (should_exit()) {
            fprintf(stderr,
                    "[curl-impersonate-mcp] self-exit: calls=%ld rss=%ld\n",
                    g_calls_handled, self_rss_bytes());
            break;
        }
    }

    free(lb.buf);
    curl_global_cleanup();
    return 0;
}
