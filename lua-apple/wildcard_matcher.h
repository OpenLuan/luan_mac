#ifndef WILDCARD_MATCHER_C_H
#define WILDCARD_MATCHER_C_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdbool.h>
#include <stdint.h>

/**
 * Wildcard Matcher C Interface
 * ============================
 *
 * High-performance C implementation of wildcard domain matching
 * (legacy tunnel / routing helper; optional for LuanMac agent host).
 *
 * Supported patterns:
 * - "*": Single-level wildcard (matches one subdomain level)
 * - "**": Multi-level wildcard (matches zero or more subdomain levels)
 * - Mixed patterns: "api.*.example.com", "**.api.example.com", etc.
 *
 * Performance optimizations:
 * - Zero-copy string operations where possible
 * - Efficient pattern parsing and caching
 * - Optimized matching algorithms for different pattern types
 * - Memory pool allocation for frequent operations
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Pattern types for optimization */
typedef enum {
    PATTERN_EXACT = 0,      /* No wildcards - exact match */
    PATTERN_SINGLE = 1,     /* Contains only * wildcards */
    PATTERN_MULTI = 2,      /* Contains ** wildcards */
    PATTERN_MIXED = 3       /* Contains both * and ** wildcards */
} pattern_type_t;

/* Compiled pattern structure for performance */
typedef struct {
    char *pattern;          /* Original pattern string */
    pattern_type_t type;    /* Pattern type for optimization */
    int score;              /* Pre-calculated pattern score */
    char *prefix;           /* Pattern prefix (before first wildcard) */
    char *suffix;           /* Pattern suffix (after last wildcard) */
    size_t prefix_len;      /* Length of prefix */
    size_t suffix_len;      /* Length of suffix */
    bool has_prefix_wildcard; /* Starts with wildcard */
    bool has_suffix_wildcard; /* Ends with wildcard */
} compiled_pattern_t;

/* Match result structure */
typedef struct {
    bool matched;           /* Whether pattern matched */
    int score;              /* Pattern specificity score */
    const char *pattern;    /* Matching pattern */
} match_result_t;

/* Core matching functions */

/**
 * Match a single wildcard pattern against a hostname
 *
 * @param pattern Wildcard pattern (e.g., "*.example.com", "**.api.example.com")
 * @param host Target hostname to match against
 * @return true if pattern matches host, false otherwise
 */
bool wildcard_match_c(const char *pattern, const char *host);

/**
 * Calculate pattern specificity score
 * Higher scores indicate more specific patterns
 *
 * @param pattern Wildcard pattern
 * @return Specificity score (higher = more specific)
 */
int calculate_pattern_score_c(const char *pattern);

/**
 * Find best matching pattern from a list
 *
 * @param host Target hostname
 * @param patterns Array of pattern strings
 * @param count Number of patterns
 * @return Index of best matching pattern, or -1 if no match
 */
int find_best_wildcard_match_c(const char *host, const char **patterns, int count);

/* Performance-optimized functions with compiled patterns */

/**
 * Compile a pattern for repeated use
 *
 * @param pattern Pattern string to compile
 * @return Compiled pattern structure, or NULL on error
 */
compiled_pattern_t *compile_pattern_c(const char *pattern);

/**
 * Free compiled pattern
 *
 * @param compiled_pattern Compiled pattern to free
 */
void free_compiled_pattern_c(compiled_pattern_t *compiled_pattern);

/**
 * Match using compiled pattern (faster for repeated matching)
 *
 * @param compiled_pattern Pre-compiled pattern
 * @param host Target hostname
 * @return true if pattern matches host, false otherwise
 */
bool wildcard_match_compiled_c(const compiled_pattern_t *compiled_pattern, const char *host);

/* Lua C API functions */

/**
 * Lua binding: wildcard_matcher_c.match(pattern, host)
 */
int lua_wildcard_match(lua_State *L);

/**
 * Lua binding: wildcard_matcher_c.calculate_score(pattern)
 */
int lua_calculate_pattern_score(lua_State *L);

/**
 * Lua binding: wildcard_matcher_c.find_best_match(host, patterns)
 */
int lua_find_best_wildcard_match(lua_State *L);

/**
 * Lua binding: wildcard_matcher_c.compile_pattern(pattern)
 */
int lua_compile_pattern(lua_State *L);

/**
 * Lua binding: wildcard_matcher_c.match_compiled(compiled_pattern, host)
 */
int lua_wildcard_match_compiled(lua_State *L);

/**
 * Initialize the Lua module
 */
int luaopen_wildcard_matcher(lua_State *L);

/* Utility functions */

/**
 * Count occurrences of substring in string
 */
int count_occurrences(const char *str, const char *substr);

/**
 * Case-insensitive string comparison
 */
int strcasecmp_c(const char *s1, const char *s2);

/**
 * Check if string ends with suffix
 */
bool str_ends_with(const char *str, const char *suffix);

/**
 * Check if string starts with prefix
 */
bool str_starts_with(const char *str, const char *prefix);

#ifdef __cplusplus
}
#endif

#endif /* WILDCARD_MATCHER_C_H */
