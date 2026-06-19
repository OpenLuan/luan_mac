#include "utlua.h"

#include <brotli/decode.h>
#include <brotli/encode.h>

#define LUA_BROTLI_TYPE "<brotli>"
#define BUF_LEN 4096

typedef struct {
//    uint8_t* input;
//    uint8_t* output;
//
//    size_t available_in;
//    const uint8_t* next_in;
//    size_t available_out;
//    uint8_t* next_out;
//
//    size_t total_in;
//    size_t total_out;
    
    BrotliDecoderState *s;
} BrotliContext;


LUA_API int luabrotli_compress(lua_State *L) {
    BrotliEncoderState* s = BrotliEncoderCreateInstance(NULL, NULL, NULL);
    size_t available_in = 0;
    const uint8_t* input = (const uint8_t*) lua_tolstring(L, 1, &available_in);
    
    size_t available_out = BUF_LEN;
    const uint8_t* next_in = input;
    uint8_t* output = lua_newuserdata(L, BUF_LEN);
    uint8_t* next_out = output;
    
    int count = 0;
    
    int returnValue = 0;

    while (true) {
        if (BrotliEncoderCompressStream(s,
                                        BROTLI_OPERATION_FINISH,
                                        &available_in, &next_in,
                                        &available_out, &next_out, NULL)) {
            if (available_out == 0) {
                size_t size = next_out - output;
                if (size > 0) {
                    lua_pushlstring(L, (const void *) output, size);
                    count++;
                }
                available_out = BUF_LEN;
                next_out = output;
            }
            
            if (BrotliEncoderIsFinished(s)) {
                size_t size = next_out - output;
                if (size > 0) {
                    lua_pushlstring(L, (const void *) output, size);
                    count++;
                }
                
                lua_concat(L, count);
                returnValue = 1;
                break;
            }
        } else {
            break;
        }
    }
    
    BrotliEncoderDestroyInstance(s);
    return returnValue;
}

LUA_API int luabrotli_decompress(lua_State *L) {
    BrotliDecoderState *s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    size_t available_in = 0;
    const uint8_t* input = (const uint8_t*) lua_tolstring(L, 1, &available_in);
    
    BrotliDecoderResult result = BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT;
    
    size_t available_out = BUF_LEN;
    const uint8_t* next_in = input;
    uint8_t* output = malloc(BUF_LEN);
    uint8_t* next_out = output;
    size_t total = 0;

    int returnValue = 0;
    
    while (true) {
        result = BrotliDecoderDecompressStream(s, &available_in,
                                               &next_in, &available_out, &next_out, &total);

        if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
            // data error
            break;
        } else if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            output = realloc(output, total + BUF_LEN);
            available_out = BUF_LEN;
            next_out = output + total;
        } else if (result == BROTLI_DECODER_RESULT_SUCCESS) {
            lua_pushlstring(L, (const void *) output, total);
            returnValue = 1;
            break;
        }
    }
    
    free(output);
    BrotliDecoderDestroyInstance(s);
    return returnValue;
}

LUA_API int luabrotli_new(lua_State *L) {
    BrotliContext *context = lua_newuserdata(L, sizeof(BrotliContext));
    luaL_getmetatable(L, LUA_BROTLI_TYPE);
    lua_setmetatable(L, -2);
    
    context->s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    
    return 1;
}

static const struct luaL_Reg brotlilib[] = {
    {"compress", luabrotli_compress},
    {"decompress", luabrotli_decompress},

    {NULL, NULL},
};

LUA_API int luaopen_brotli(lua_State *L)
{
    lua_newtable(L);
    luaL_register(L, "brotli", brotlilib);
    return 1;
}
