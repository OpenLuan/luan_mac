#include "wildcard_matcher.h"
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <stdio.h>

/* Constants for performance tuning */
#define MAX_PATTERN_LENGTH 256
#define MAX_HOST_LENGTH 256
#define SINGLE_WILDCARD_PENALTY 5
#define MULTI_WILDCARD_PENALTY 10

/* Forward declarations */
static bool match_single_level_recursive(const char *pattern, const char *host);
static int match_prefix_pattern(const char *prefix_pattern, const char *host);
static int match_suffix_pattern(const char *suffix_pattern, const char *host);
static bool match_multi_level_wildcard(const char *pattern, const char *host);
static bool match_single_level_wildcard(const char *pattern, const char *host);
static void extract_pattern_parts(compiled_pattern_t *compiled);
static int lua_compiled_pattern_gc(lua_State *L);

/* Utility functions */

int count_occurrences(const char *str, const char *substr) {
    int count = 0;
    const char *pos = str;
    size_t substr_len = strlen(substr);

    while ((pos = strstr(pos, substr)) != NULL) {
        count++;
        pos += substr_len;
    }
    return count;
}

int strcasecmp_c(const char *s1, const char *s2) {
    while (*s1 && *s2) {
        int diff = tolower(*s1) - tolower(*s2);
        if (diff != 0) return diff;
        s1++;
        s2++;
    }
    return tolower(*s1) - tolower(*s2);
}

bool str_ends_with(const char *str, const char *suffix) {
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);

    if (suffix_len > str_len) return false;
    return strcasecmp_c(str + str_len - suffix_len, suffix) == 0;
}

bool str_starts_with(const char *str, const char *prefix) {
    size_t prefix_len = strlen(prefix);
    return strncasecmp(str, prefix, prefix_len) == 0;
}

/* Core wildcard matching implementation */

bool wildcard_match_c(const char *pattern, const char *host) {
    if (!pattern || !host) return false;

    /* Exact match check */
    if (strcasecmp_c(pattern, host) == 0) {
        return true;
    }

    /* If no wildcards, and not exact match, then no match */
    if (strstr(pattern, "*") == NULL) {
        return false;
    }

    /* Handle multi-level wildcard (**) patterns */
    if (strstr(pattern, "**") != NULL) {
        return match_multi_level_wildcard(pattern, host);
    }

    /* Handle single-level wildcard (*) patterns */
    return match_single_level_wildcard(pattern, host);
}

/* Helper: check if pattern prefix matches beginning of host.
   prefix_pattern may contain single-level wildcards (*).
   Returns the length of the matched portion, or -1 if no match.
   Tries to find the shortest match so ** can consume the rest. */
static int match_prefix_pattern(const char *prefix_pattern, const char *host) {
    size_t plen = strlen(prefix_pattern);
    size_t hlen = strlen(host);

    if (plen == 0) return 0;

    /* If prefix has no wildcards, do literal comparison */
    if (strchr(prefix_pattern, '*') == NULL) {
        if (hlen >= plen && strncmp(host, prefix_pattern, plen) == 0) {
            return (int)plen;
        }
        return -1;
    }

    /* Prefix contains wildcards - try matching against increasing lengths of host.
       Single-level wildcard (*) cannot cross dots, so we try up to each dot boundary. */
    for (size_t len = plen > 0 ? 1 : 0; len <= hlen; len++) {
        /* Create a temporary substring of host[0..len-1] */
        char tmp[MAX_HOST_LENGTH];
        if (len >= sizeof(tmp)) break;
        strncpy(tmp, host, len);
        tmp[len] = '\0';

        if (match_single_level_recursive(prefix_pattern, tmp)) {
            return (int)len;
        }
    }
    return -1;
}

/* Helper: check if pattern suffix matches end of host.
   suffix_pattern may contain single-level wildcards (*).
   Returns the length of the matched suffix portion, or -1 if no match. */
static int match_suffix_pattern(const char *suffix_pattern, const char *host) {
    size_t slen = strlen(suffix_pattern);
    size_t hlen = strlen(host);

    if (slen == 0) return 0;

    /* If suffix has no wildcards, do literal comparison */
    if (strchr(suffix_pattern, '*') == NULL) {
        if (hlen >= slen && strcmp(host + hlen - slen, suffix_pattern) == 0) {
            return (int)slen;
        }
        return -1;
    }

    /* Suffix contains wildcards - try matching from each possible start position */
    for (size_t start = 0; start <= hlen; start++) {
        const char *candidate = host + start;
        if (match_single_level_recursive(suffix_pattern, candidate)) {
            return (int)(hlen - start);
        }
    }
    return -1;
}

static bool match_multi_level_wildcard(const char *pattern, const char *host) {
    char *pattern_copy = strdup(pattern);
    char *host_lower = strdup(host);
    bool result = false;

    /* Convert to lowercase for case-insensitive matching */
    for (char *p = host_lower; *p; p++) *p = tolower(*p);
    for (char *p = pattern_copy; *p; p++) *p = tolower(*p);

    /* Find the ** position */
    char *double_star = strstr(pattern_copy, "**");
    if (!double_star) {
        goto cleanup;
    }

    /* Split pattern into prefix and suffix */
    *double_star = '\0';
    char *prefix = pattern_copy;
    char *suffix = double_star + 2;  /* Skip past "**" */

    size_t prefix_len = strlen(prefix);
    size_t suffix_len = strlen(suffix);

    if (prefix_len == 0) {
        /* Pattern like "**.example.com" */
        if (suffix_len == 0) {
            /* Pattern is just "**" - matches everything */
            result = true;
        } else if (suffix[0] == '.') {
            /* Check for exact match with suffix without leading dot */
            const char *suffix_no_dot = suffix + 1;
            if (strchr(suffix_no_dot, '*') != NULL) {
                /* Suffix contains wildcards */
                if (match_single_level_recursive(suffix_no_dot, host_lower)) {
                    result = true;
                } else if (match_suffix_pattern(suffix, host_lower) >= 0) {
                    result = true;
                }
            } else {
                if (strcmp(host_lower, suffix_no_dot) == 0) {
                    result = true;
                } else if (str_ends_with(host_lower, suffix)) {
                    result = true;
                }
            }
        }
    } else {
        /* Pattern like "api.**.example.com" or "*.sfmobile.**.hana.ondemand.com" */
        if (suffix_len == 0) {
            /* Pattern like "api.**" or "*.sfmobile.**" */
            int matched = match_prefix_pattern(prefix, host_lower);
            result = (matched >= 0);
        } else {
            /* Check for zero-level match first (** matches zero segments) */
            if (suffix[0] == '.') {
                char zero_level_pattern[MAX_PATTERN_LENGTH];
                snprintf(zero_level_pattern, sizeof(zero_level_pattern), "%s%s", prefix, suffix + 1);
                if (match_single_level_recursive(zero_level_pattern, host_lower)) {
                    result = true;
                    goto cleanup;
                }
            }

            /* Check prefix match using wildcard-aware function */
            int prefix_matched = match_prefix_pattern(prefix, host_lower);
            if (prefix_matched >= 0) {
                /* Check suffix match on the remaining portion */
                const char *remaining = host_lower + prefix_matched;
                int suffix_matched = match_suffix_pattern(suffix, remaining);
                if (suffix_matched >= 0) {
                    result = true;
                }
            }
        }
    }

cleanup:
    free(pattern_copy);
    free(host_lower);
    return result;
}

static bool match_single_level_wildcard(const char *pattern, const char *host) {
    char pattern_copy[MAX_PATTERN_LENGTH];
    char host_lower[MAX_HOST_LENGTH];

    /* Convert to lowercase */
    strncpy(pattern_copy, pattern, sizeof(pattern_copy) - 1);
    pattern_copy[sizeof(pattern_copy) - 1] = '\0';
    strncpy(host_lower, host, sizeof(host_lower) - 1);
    host_lower[sizeof(host_lower) - 1] = '\0';

    for (char *p = pattern_copy; *p; p++) *p = tolower(*p);
    for (char *p = host_lower; *p; p++) *p = tolower(*p);

    return match_single_level_recursive(pattern_copy, host_lower);
}

static bool match_single_level_recursive(const char *pattern, const char *host) {
    const char *p = pattern;
    const char *h = host;

    while (*p && *h) {
        if (*p == '*') {
            /* Skip consecutive asterisks */
            while (*p == '*') p++;

            if (!*p) {
                /* Pattern ends with *, check if remaining host has no dots */
                while (*h) {
                    if (*h == '.') return false;
                    h++;
                }
                return true;
            }

            /* Find the next non-wildcard character in pattern */
            char next_char = *p;

            /* Try to match the rest of the pattern starting from each position in host */
            while (*h) {
                if (*h == next_char) {
                    if (match_single_level_recursive(p, h)) {
                        return true;
                    }
                }
                /* Single * cannot match across dots */
                if (*h == '.') return false;
                h++;
            }
            return false;
        } else {
            /* Regular character matching */
            if (*p != *h) return false;
            p++;
            h++;
        }
    }

    /* Handle remaining pattern */
    while (*p == '*') p++;

    return (*p == '\0' && *h == '\0');
}

int calculate_pattern_score_c(const char *pattern) {
    if (!pattern) return 0;

    int score = (int)strlen(pattern);  /* Base score: pattern length */

    /* Count ** patterns first (higher penalty) */
    int double_star_count = count_occurrences(pattern, "**");
    score -= double_star_count * MULTI_WILDCARD_PENALTY;

    /* Count remaining single * patterns */
    int single_star_count = 0;
    const char *pos = pattern;
    while ((pos = strchr(pos, '*')) != NULL) {
        /* Skip if this is part of ** */
        if (pos > pattern && *(pos - 1) == '*') {
            pos++;
            continue;
        }
        if (*(pos + 1) == '*') {
            pos += 2;  /* Skip the ** */
            continue;
        }
        single_star_count++;
        pos++;
    }

    score -= single_star_count * SINGLE_WILDCARD_PENALTY;

    return score;
}

int find_best_wildcard_match_c(const char *host, const char **patterns, int count) {
    int best_index = -1;
    int best_score = -1;

    for (int i = 0; i < count; i++) {
        if (wildcard_match_c(patterns[i], host)) {
            int score = calculate_pattern_score_c(patterns[i]);
            if (score > best_score) {
                best_score = score;
                best_index = i;
            }
        }
    }

    return best_index;
}

/* Compiled pattern functions for performance optimization */

compiled_pattern_t *compile_pattern_c(const char *pattern) {
    if (!pattern) return NULL;

    compiled_pattern_t *compiled = malloc(sizeof(compiled_pattern_t));
    if (!compiled) return NULL;

    memset(compiled, 0, sizeof(compiled_pattern_t));

    /* Store original pattern */
    compiled->pattern = strdup(pattern);
    if (!compiled->pattern) {
        free(compiled);
        return NULL;
    }

    /* Pre-calculate score */
    compiled->score = calculate_pattern_score_c(pattern);

    /* Determine pattern type */
    bool has_single = strstr(pattern, "*") != NULL;
    bool has_double = strstr(pattern, "**") != NULL;

    if (!has_single && !has_double) {
        compiled->type = PATTERN_EXACT;
    } else if (has_double) {
        compiled->type = has_single ? PATTERN_MIXED : PATTERN_MULTI;
    } else {
        compiled->type = PATTERN_SINGLE;
    }

    /* Extract prefix and suffix for optimization */
    extract_pattern_parts(compiled);

    return compiled;
}

static void extract_pattern_parts(compiled_pattern_t *compiled) {
    const char *pattern = compiled->pattern;
    const char *first_star = strchr(pattern, '*');

    if (!first_star) {
        /* No wildcards */
        return;
    }

    /* Extract prefix (part before first wildcard) */
    size_t prefix_len = first_star - pattern;
    if (prefix_len > 0) {
        compiled->prefix = malloc(prefix_len + 1);
        if (compiled->prefix) {
            strncpy(compiled->prefix, pattern, prefix_len);
            compiled->prefix[prefix_len] = '\0';
            compiled->prefix_len = prefix_len;
        }
    }

    /* Find last wildcard for suffix extraction */
    const char *last_star = strrchr(pattern, '*');
    if (last_star) {
        const char *suffix_start = last_star + 1;
        size_t suffix_len = strlen(suffix_start);
        if (suffix_len > 0) {
            compiled->suffix = strdup(suffix_start);
            compiled->suffix_len = suffix_len;
        }
    }

    compiled->has_prefix_wildcard = (first_star == pattern);
    compiled->has_suffix_wildcard = (last_star == pattern + strlen(pattern) - 1);
}

void free_compiled_pattern_c(compiled_pattern_t *compiled_pattern) {
    if (!compiled_pattern) return;

    free(compiled_pattern->pattern);
    free(compiled_pattern->prefix);
    free(compiled_pattern->suffix);
    free(compiled_pattern);
}

bool wildcard_match_compiled_c(const compiled_pattern_t *compiled_pattern, const char *host) {
    if (!compiled_pattern || !host) return false;

    /* Use the original function for now - could be optimized further */
    return wildcard_match_c(compiled_pattern->pattern, host);
}

/* Lua C API bindings */

int lua_wildcard_match(lua_State *L) {
    const char *pattern = luaL_checkstring(L, 1);
    const char *host = luaL_checkstring(L, 2);

    bool result = wildcard_match_c(pattern, host);
    lua_pushboolean(L, result);
    return 1;
}

int lua_calculate_pattern_score(lua_State *L) {
    const char *pattern = luaL_checkstring(L, 1);

    int score = calculate_pattern_score_c(pattern);
    lua_pushinteger(L, score);
    return 1;
}

int lua_find_best_wildcard_match(lua_State *L) {
    const char *host = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    /* Get table size */
    int count = lua_rawlen(L, 2);
    if (count == 0) {
        lua_pushnil(L);
        return 1;
    }

    /* Extract patterns from Lua table */
    const char **patterns = malloc(count * sizeof(char*));
    if (!patterns) {
        return luaL_error(L, "Memory allocation failed");
    }

    for (int i = 0; i < count; i++) {
        lua_rawgeti(L, 2, i + 1);  /* Lua arrays are 1-indexed */
        patterns[i] = lua_tostring(L, -1);
        lua_pop(L, 1);
    }

    int best_index = find_best_wildcard_match_c(host, patterns, count);

    free(patterns);

    if (best_index >= 0) {
        lua_pushinteger(L, best_index + 1);  /* Convert back to 1-indexed */
    } else {
        lua_pushnil(L);
    }

    return 1;
}

int lua_compile_pattern(lua_State *L) {
    const char *pattern = luaL_checkstring(L, 1);

    compiled_pattern_t *compiled = compile_pattern_c(pattern);
    if (!compiled) {
        return luaL_error(L, "Failed to compile pattern");
    }

    /* Create userdata to hold the compiled pattern */
    compiled_pattern_t **udata = (compiled_pattern_t**)lua_newuserdata(L, sizeof(compiled_pattern_t*));
    *udata = compiled;

    /* Set metatable for garbage collection */
    luaL_getmetatable(L, "wildcard_compiled_pattern");
    lua_setmetatable(L, -2);

    return 1;
}

int lua_wildcard_match_compiled(lua_State *L) {
    compiled_pattern_t **compiled_ptr = (compiled_pattern_t**)luaL_checkudata(L, 1, "wildcard_compiled_pattern");
    const char *host = luaL_checkstring(L, 2);

    if (!compiled_ptr || !*compiled_ptr) {
        return luaL_error(L, "Invalid compiled pattern");
    }

    bool result = wildcard_match_compiled_c(*compiled_ptr, host);
    lua_pushboolean(L, result);
    return 1;
}

/* Garbage collection for compiled patterns */
static int lua_compiled_pattern_gc(lua_State *L) {
    compiled_pattern_t **compiled_ptr = (compiled_pattern_t**)luaL_checkudata(L, 1, "wildcard_compiled_pattern");
    if (compiled_ptr && *compiled_ptr) {
        free_compiled_pattern_c(*compiled_ptr);
        *compiled_ptr = NULL;
    }
    return 0;
}

/* Module registration */
static const luaL_Reg wildcard_matcher_functions[] = {
    {"match", lua_wildcard_match},
    {"calculate_score", lua_calculate_pattern_score},
    {"find_best_match", lua_find_best_wildcard_match},
    {"compile_pattern", lua_compile_pattern},
    {"match_compiled", lua_wildcard_match_compiled},
    {NULL, NULL}
};

int luaopen_wildcard_matcher(lua_State *L) {
    /* Create metatable for compiled patterns */
    luaL_newmetatable(L, "wildcard_compiled_pattern");
    lua_pushcfunction(L, lua_compiled_pattern_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    /* Create and register the module */
    luaL_newlib(L, wildcard_matcher_functions);

    /* Add version information */
    lua_pushstring(L, "1.0.0");
    lua_setfield(L, -2, "_VERSION");

    return 1;
}