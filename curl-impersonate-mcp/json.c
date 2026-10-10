/* json.c — minimal JSON parser/encoder; see json.h for scope. */

#include "json.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- allocation helpers --------------------------------------------- */

static json_value_t *alloc_value(json_type_t t) {
    json_value_t *v = (json_value_t *)calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->type = t;
    return v;
}

static char *dup_bytes(const char *s, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    if (len) memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

json_value_t *json_new_null(void) { return alloc_value(JSON_NULL); }

json_value_t *json_new_bool(int b) {
    json_value_t *v = alloc_value(JSON_BOOL);
    if (v) v->bval = b ? 1 : 0;
    return v;
}

json_value_t *json_new_number(double n) {
    json_value_t *v = alloc_value(JSON_NUMBER);
    if (v) v->num = n;
    return v;
}

json_value_t *json_new_string(const char *s, size_t len) {
    json_value_t *v = alloc_value(JSON_STRING);
    if (!v) return NULL;
    v->str = dup_bytes(s ? s : "", len);
    if (!v->str) { free(v); return NULL; }
    v->str_len = len;
    return v;
}

json_value_t *json_new_array(void) { return alloc_value(JSON_ARRAY); }
json_value_t *json_new_object(void) { return alloc_value(JSON_OBJECT); }

static void append_child(json_value_t *parent, json_value_t *child) {
    child->next = NULL;
    if (!parent->first) {
        parent->first = child;
    } else {
        parent->last->next = child;
    }
    parent->last = child;
}

int json_array_push(json_value_t *arr, json_value_t *child) {
    if (!arr || !child || arr->type != JSON_ARRAY) { json_free(child); return -1; }
    append_child(arr, child);
    return 0;
}

int json_object_set(json_value_t *obj, const char *key, size_t key_len,
                    json_value_t *child) {
    if (!obj || !child || obj->type != JSON_OBJECT || !key) {
        json_free(child); return -1;
    }
    char *k = dup_bytes(key, key_len);
    if (!k) { json_free(child); return -1; }
    child->key = k;
    child->key_len = key_len;
    append_child(obj, child);
    return 0;
}

void json_free(json_value_t *v) {
    if (!v) return;
    json_value_t *c = v->first;
    while (c) {
        json_value_t *n = c->next;
        json_free(c);
        c = n;
    }
    free(v->str);
    free(v->key);
    free(v);
}

/* ---- accessors ------------------------------------------------------ */

json_value_t *json_object_get(const json_value_t *obj, const char *key) {
    if (!obj || obj->type != JSON_OBJECT || !key) return NULL;
    size_t klen = strlen(key);
    for (json_value_t *c = obj->first; c; c = c->next) {
        if (c->key_len == klen && c->key && memcmp(c->key, key, klen) == 0) return c;
    }
    return NULL;
}

const char *json_as_string(const json_value_t *v, size_t *len_out) {
    if (!v || v->type != JSON_STRING) {
        if (len_out) *len_out = 0;
        return NULL;
    }
    if (len_out) *len_out = v->str_len;
    return v->str;
}

double json_as_number(const json_value_t *v, double fallback) {
    if (!v) return fallback;
    if (v->type == JSON_NUMBER) return v->num;
    if (v->type == JSON_BOOL) return v->bval ? 1.0 : 0.0;
    return fallback;
}

int json_as_bool(const json_value_t *v, int fallback) {
    if (!v) return fallback;
    if (v->type == JSON_BOOL) return v->bval;
    if (v->type == JSON_NUMBER) return v->num != 0.0;
    return fallback;
}

/* ---- parser --------------------------------------------------------- */

typedef struct {
    const char *src;
    size_t len;
    size_t pos;
    const char *err;
} parser_t;

static void skip_ws(parser_t *p) {
    while (p->pos < p->len) {
        char c = p->src[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

static int peek(parser_t *p, char *out) {
    if (p->pos >= p->len) return 0;
    *out = p->src[p->pos];
    return 1;
}

static int match_literal(parser_t *p, const char *lit) {
    size_t llen = strlen(lit);
    if (p->pos + llen > p->len) return 0;
    if (memcmp(p->src + p->pos, lit, llen) != 0) return 0;
    p->pos += llen;
    return 1;
}

/* Append one byte to a growable buffer. Returns 0 ok, -1 oom. */
static int buf_push(char **buf, size_t *len, size_t *cap, char c) {
    if (*len + 1 >= *cap) {
        size_t ncap = *cap ? *cap * 2 : 32;
        char *nbuf = (char *)realloc(*buf, ncap);
        if (!nbuf) return -1;
        *buf = nbuf;
        *cap = ncap;
    }
    (*buf)[(*len)++] = c;
    return 0;
}

/* Encode a Unicode code point as UTF-8 and append. */
static int buf_push_cp(char **buf, size_t *len, size_t *cap, unsigned cp) {
    if (cp < 0x80) {
        return buf_push(buf, len, cap, (char)cp);
    } else if (cp < 0x800) {
        if (buf_push(buf, len, cap, (char)(0xC0 | (cp >> 6))) < 0) return -1;
        return buf_push(buf, len, cap, (char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        if (buf_push(buf, len, cap, (char)(0xE0 | (cp >> 12))) < 0) return -1;
        if (buf_push(buf, len, cap, (char)(0x80 | ((cp >> 6) & 0x3F))) < 0) return -1;
        return buf_push(buf, len, cap, (char)(0x80 | (cp & 0x3F)));
    } else if (cp <= 0x10FFFF) {
        if (buf_push(buf, len, cap, (char)(0xF0 | (cp >> 18))) < 0) return -1;
        if (buf_push(buf, len, cap, (char)(0x80 | ((cp >> 12) & 0x3F))) < 0) return -1;
        if (buf_push(buf, len, cap, (char)(0x80 | ((cp >> 6) & 0x3F))) < 0) return -1;
        return buf_push(buf, len, cap, (char)(0x80 | (cp & 0x3F)));
    }
    return -1;
}

static int parse_hex4(parser_t *p, unsigned *out) {
    if (p->pos + 4 > p->len) return -1;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = p->src[p->pos + i];
        unsigned d;
        if (c >= '0' && c <= '9') d = (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') d = (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = (unsigned)(c - 'A' + 10);
        else return -1;
        v = (v << 4) | d;
    }
    p->pos += 4;
    *out = v;
    return 0;
}

static json_value_t *parse_string(parser_t *p) {
    /* assumes `"` is at p->pos */
    if (p->pos >= p->len || p->src[p->pos] != '"') { p->err = "expected '\"'"; return NULL; }
    p->pos++;
    char *buf = NULL;
    size_t len = 0, cap = 0;
    while (p->pos < p->len) {
        unsigned char c = (unsigned char)p->src[p->pos++];
        if (c == '"') {
            if (buf_push(&buf, &len, &cap, '\0') < 0) { free(buf); p->err = "oom"; return NULL; }
            len--; /* don't count the NUL */
            json_value_t *v = alloc_value(JSON_STRING);
            if (!v) { free(buf); p->err = "oom"; return NULL; }
            v->str = buf;
            v->str_len = len;
            return v;
        }
        if (c == '\\') {
            if (p->pos >= p->len) { free(buf); p->err = "bad escape"; return NULL; }
            char esc = p->src[p->pos++];
            char out = 0;
            switch (esc) {
                case '"': out = '"'; break;
                case '\\': out = '\\'; break;
                case '/': out = '/'; break;
                case 'b': out = '\b'; break;
                case 'f': out = '\f'; break;
                case 'n': out = '\n'; break;
                case 'r': out = '\r'; break;
                case 't': out = '\t'; break;
                case 'u': {
                    unsigned cp;
                    if (parse_hex4(p, &cp) < 0) { free(buf); p->err = "bad \\u"; return NULL; }
                    /* UTF-16 surrogate pair? */
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        if (p->pos + 2 > p->len || p->src[p->pos] != '\\' || p->src[p->pos+1] != 'u') {
                            free(buf); p->err = "unpaired high surrogate"; return NULL;
                        }
                        p->pos += 2;
                        unsigned low;
                        if (parse_hex4(p, &low) < 0 || low < 0xDC00 || low > 0xDFFF) {
                            free(buf); p->err = "bad surrogate pair"; return NULL;
                        }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        free(buf); p->err = "unpaired low surrogate"; return NULL;
                    }
                    if (buf_push_cp(&buf, &len, &cap, cp) < 0) { free(buf); p->err = "oom"; return NULL; }
                    continue;
                }
                default: free(buf); p->err = "bad escape"; return NULL;
            }
            if (buf_push(&buf, &len, &cap, out) < 0) { free(buf); p->err = "oom"; return NULL; }
            continue;
        }
        if (c < 0x20) { free(buf); p->err = "control char in string"; return NULL; }
        if (buf_push(&buf, &len, &cap, (char)c) < 0) { free(buf); p->err = "oom"; return NULL; }
    }
    free(buf);
    p->err = "unterminated string";
    return NULL;
}

static json_value_t *parse_value(parser_t *p);

static json_value_t *parse_array(parser_t *p) {
    /* assumes `[` */
    p->pos++;
    json_value_t *arr = json_new_array();
    if (!arr) { p->err = "oom"; return NULL; }
    skip_ws(p);
    char c;
    if (peek(p, &c) && c == ']') { p->pos++; return arr; }
    while (p->pos < p->len) {
        json_value_t *elem = parse_value(p);
        if (!elem) { json_free(arr); return NULL; }
        append_child(arr, elem);
        skip_ws(p);
        if (!peek(p, &c)) { json_free(arr); p->err = "unterminated array"; return NULL; }
        if (c == ',') { p->pos++; skip_ws(p); continue; }
        if (c == ']') { p->pos++; return arr; }
        json_free(arr);
        p->err = "expected ',' or ']'";
        return NULL;
    }
    json_free(arr);
    p->err = "unterminated array";
    return NULL;
}

static json_value_t *parse_object(parser_t *p) {
    p->pos++;
    json_value_t *obj = json_new_object();
    if (!obj) { p->err = "oom"; return NULL; }
    skip_ws(p);
    char c;
    if (peek(p, &c) && c == '}') { p->pos++; return obj; }
    while (p->pos < p->len) {
        skip_ws(p);
        if (!peek(p, &c) || c != '"') { json_free(obj); p->err = "expected string key"; return NULL; }
        json_value_t *key = parse_string(p);
        if (!key) { json_free(obj); return NULL; }
        skip_ws(p);
        if (!peek(p, &c) || c != ':') {
            json_free(key); json_free(obj);
            p->err = "expected ':'";
            return NULL;
        }
        p->pos++;
        skip_ws(p);
        json_value_t *val = parse_value(p);
        if (!val) { json_free(key); json_free(obj); return NULL; }
        /* Move key ownership into child slot. */
        val->key = key->str;
        val->key_len = key->str_len;
        key->str = NULL;
        key->str_len = 0;
        json_free(key);
        append_child(obj, val);
        skip_ws(p);
        if (!peek(p, &c)) { json_free(obj); p->err = "unterminated object"; return NULL; }
        if (c == ',') { p->pos++; continue; }
        if (c == '}') { p->pos++; return obj; }
        json_free(obj);
        p->err = "expected ',' or '}'";
        return NULL;
    }
    json_free(obj);
    p->err = "unterminated object";
    return NULL;
}

static json_value_t *parse_number(parser_t *p) {
    size_t start = p->pos;
    if (p->pos < p->len && p->src[p->pos] == '-') p->pos++;
    while (p->pos < p->len && isdigit((unsigned char)p->src[p->pos])) p->pos++;
    if (p->pos < p->len && p->src[p->pos] == '.') {
        p->pos++;
        while (p->pos < p->len && isdigit((unsigned char)p->src[p->pos])) p->pos++;
    }
    if (p->pos < p->len && (p->src[p->pos] == 'e' || p->src[p->pos] == 'E')) {
        p->pos++;
        if (p->pos < p->len && (p->src[p->pos] == '+' || p->src[p->pos] == '-')) p->pos++;
        while (p->pos < p->len && isdigit((unsigned char)p->src[p->pos])) p->pos++;
    }
    if (p->pos == start) { p->err = "expected number"; return NULL; }
    char tmp[64];
    size_t n = p->pos - start;
    if (n >= sizeof(tmp)) { p->err = "number too long"; return NULL; }
    memcpy(tmp, p->src + start, n);
    tmp[n] = '\0';
    char *endp = NULL;
    double d = strtod(tmp, &endp);
    if (endp == tmp) { p->err = "bad number"; return NULL; }
    return json_new_number(d);
}

static json_value_t *parse_value(parser_t *p) {
    skip_ws(p);
    char c;
    if (!peek(p, &c)) { p->err = "unexpected end"; return NULL; }
    if (c == '"') return parse_string(p);
    if (c == '{') return parse_object(p);
    if (c == '[') return parse_array(p);
    if (c == 't' && match_literal(p, "true")) return json_new_bool(1);
    if (c == 'f' && match_literal(p, "false")) return json_new_bool(0);
    if (c == 'n' && match_literal(p, "null")) return json_new_null();
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p);
    p->err = "unexpected char";
    return NULL;
}

json_value_t *json_parse(const char *src, size_t len, const char **err) {
    parser_t p = { src, len, 0, NULL };
    json_value_t *v = parse_value(&p);
    if (!v) { if (err) *err = p.err ? p.err : "parse error"; return NULL; }
    skip_ws(&p);
    if (p.pos != len) { json_free(v); if (err) *err = "trailing data"; return NULL; }
    return v;
}

/* ---- encoder -------------------------------------------------------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
    int oom;
} enc_t;

static void enc_push(enc_t *e, char c) {
    if (e->oom) return;
    if (e->len + 1 >= e->cap) {
        size_t ncap = e->cap ? e->cap * 2 : 128;
        char *nb = (char *)realloc(e->buf, ncap);
        if (!nb) { e->oom = 1; return; }
        e->buf = nb;
        e->cap = ncap;
    }
    e->buf[e->len++] = c;
}

static void enc_puts(enc_t *e, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) enc_push(e, s[i]);
}

static void enc_string(enc_t *e, const char *s, size_t n) {
    enc_push(e, '"');
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"':  enc_puts(e, "\\\"", 2); break;
            case '\\': enc_puts(e, "\\\\", 2); break;
            case '\b': enc_puts(e, "\\b", 2); break;
            case '\f': enc_puts(e, "\\f", 2); break;
            case '\n': enc_puts(e, "\\n", 2); break;
            case '\r': enc_puts(e, "\\r", 2); break;
            case '\t': enc_puts(e, "\\t", 2); break;
            default:
                if (c < 0x20) {
                    char tmp[8];
                    int w = snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                    if (w > 0) enc_puts(e, tmp, (size_t)w);
                } else {
                    enc_push(e, (char)c);
                }
                break;
        }
    }
    enc_push(e, '"');
}

static void enc_number(enc_t *e, double n) {
    char tmp[64];
    /* Prefer integer formatting when the number is a whole number within
     * safe int range — matches mcp_client expectations (JSON-RPC ids are
     * integers). */
    if (n == (double)(long long)n && n >= -9007199254740992.0 && n <= 9007199254740992.0) {
        int w = snprintf(tmp, sizeof(tmp), "%lld", (long long)n);
        if (w > 0) enc_puts(e, tmp, (size_t)w);
        return;
    }
    int w = snprintf(tmp, sizeof(tmp), "%.17g", n);
    if (w > 0) enc_puts(e, tmp, (size_t)w);
}

static void enc_value(enc_t *e, const json_value_t *v) {
    if (!v) { enc_puts(e, "null", 4); return; }
    switch (v->type) {
        case JSON_NULL:   enc_puts(e, "null", 4); break;
        case JSON_BOOL:   enc_puts(e, v->bval ? "true" : "false", v->bval ? 4 : 5); break;
        case JSON_NUMBER: enc_number(e, v->num); break;
        case JSON_STRING: enc_string(e, v->str ? v->str : "", v->str_len); break;
        case JSON_ARRAY: {
            enc_push(e, '[');
            int first = 1;
            for (json_value_t *c = v->first; c; c = c->next) {
                if (!first) enc_push(e, ',');
                first = 0;
                enc_value(e, c);
            }
            enc_push(e, ']');
            break;
        }
        case JSON_OBJECT: {
            enc_push(e, '{');
            int first = 1;
            for (json_value_t *c = v->first; c; c = c->next) {
                if (!first) enc_push(e, ',');
                first = 0;
                enc_string(e, c->key ? c->key : "", c->key_len);
                enc_push(e, ':');
                enc_value(e, c);
            }
            enc_push(e, '}');
            break;
        }
    }
}

char *json_encode(const json_value_t *v, size_t *len_out) {
    enc_t e = { NULL, 0, 0, 0 };
    enc_value(&e, v);
    if (e.oom) { free(e.buf); return NULL; }
    enc_push(&e, '\0');
    if (e.oom) { free(e.buf); return NULL; }
    if (len_out) *len_out = e.len - 1;
    return e.buf;
}
