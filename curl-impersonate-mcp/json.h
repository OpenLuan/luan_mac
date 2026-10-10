/* json.h — minimal JSON parser/encoder for curl-impersonate-mcp.
 *
 * This is NOT a full JSON implementation. It is tuned for the message shapes
 * actually exchanged with mcp_client.lua (JSON-RPC 2.0):
 *   - All strings are UTF-8; invalid sequences are rejected.
 *   - Numbers are stored as double; the parser accepts integer syntax.
 *   - Objects preserve insertion order (needed because tests inspect wire
 *     bytes for id/method ordering).
 *   - No duplicate-key detection (last writer wins).
 *   - No streaming; the whole document is in memory.
 *
 * Nothing here is thread-safe. The server is single-threaded by construction.
 */

#ifndef CURL_IMPERSONATE_MCP_JSON_H
#define CURL_IMPERSONATE_MCP_JSON_H

#include <stddef.h>

typedef enum {
    JSON_NULL = 0,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT
} json_type_t;

typedef struct json_value json_value_t;

/* Opaque — see json.c. */
struct json_value {
    json_type_t type;
    /* For STRING: null-terminated UTF-8 (also stores the raw bytes; may
     * contain embedded NUL). `str_len` is the exact byte length. */
    char *str;
    size_t str_len;
    double num;
    int bval;                 /* 0/1 for BOOL */
    /* ARRAY/OBJECT children, singly linked, insertion-ordered. */
    json_value_t *first;
    json_value_t *last;
    json_value_t *next;
    /* Only meaningful when this node is a child of an OBJECT. */
    char *key;
    size_t key_len;
};

/* Parse a complete JSON document. Returns NULL on error; if `err` is non-NULL
 * it is set to a short static diagnostic string. */
json_value_t *json_parse(const char *src, size_t len, const char **err);

/* Free a value tree. Safe on NULL. */
void json_free(json_value_t *v);

/* Allocate a new unattached value of each primitive type. The STRING/key
 * accessors copy their input (binary-safe; `len` is used instead of strlen). */
json_value_t *json_new_null(void);
json_value_t *json_new_bool(int b);
json_value_t *json_new_number(double n);
json_value_t *json_new_string(const char *s, size_t len);
json_value_t *json_new_array(void);
json_value_t *json_new_object(void);

/* Append `child` to an array or object. For objects, `key`/`key_len` are
 * required. The receiver takes ownership of `child`; do not free it
 * separately. Returns 0 on success, -1 on allocation failure (the child is
 * freed on failure so the caller never has to worry about leaks). */
int json_array_push(json_value_t *arr, json_value_t *child);
int json_object_set(json_value_t *obj, const char *key, size_t key_len,
                    json_value_t *child);

/* Lookup helpers. Return NULL on missing / wrong type. */
json_value_t *json_object_get(const json_value_t *obj, const char *key);
const char *json_as_string(const json_value_t *v, size_t *len_out);
double json_as_number(const json_value_t *v, double fallback);
int json_as_bool(const json_value_t *v, int fallback);

/* Encode to a newly allocated null-terminated buffer. `len_out` (optional)
 * receives the byte length (not counting the trailing NUL). Returns NULL on
 * allocation failure. The caller frees with free(). */
char *json_encode(const json_value_t *v, size_t *len_out);

#endif
