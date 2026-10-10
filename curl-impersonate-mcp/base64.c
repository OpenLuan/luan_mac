/* base64.c — see base64.h. Compact RFC 4648 implementation. */

#include "base64.h"

#include <string.h>

static const char ENC[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* 0..63 for valid alphabet bytes; 0x40 for '='; 0xFE for whitespace;
 * 0xFF for every other byte (reject). */
static unsigned char DEC[256];
static int dec_ready = 0;

static void dec_init(void) {
    if (dec_ready) return;
    for (int i = 0; i < 256; i++) DEC[i] = 0xFF;
    for (int i = 0; i < 64; i++) DEC[(unsigned char)ENC[i]] = (unsigned char)i;
    DEC[(unsigned char)'='] = 0x40;
    DEC[(unsigned char)' '] = 0xFE;
    DEC[(unsigned char)'\t'] = 0xFE;
    DEC[(unsigned char)'\n'] = 0xFE;
    DEC[(unsigned char)'\r'] = 0xFE;
    dec_ready = 1;
}

size_t base64_encoded_size(size_t len) {
    return ((len + 2) / 3) * 4;
}

size_t base64_encode(const unsigned char *in, size_t len, char *out) {
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = ((unsigned)in[i] << 16) | ((unsigned)in[i+1] << 8) | in[i+2];
        out[o++] = ENC[(v >> 18) & 0x3F];
        out[o++] = ENC[(v >> 12) & 0x3F];
        out[o++] = ENC[(v >> 6) & 0x3F];
        out[o++] = ENC[v & 0x3F];
        i += 3;
    }
    if (i < len) {
        unsigned v = (unsigned)in[i] << 16;
        if (i + 1 < len) v |= (unsigned)in[i+1] << 8;
        out[o++] = ENC[(v >> 18) & 0x3F];
        out[o++] = ENC[(v >> 12) & 0x3F];
        out[o++] = (i + 1 < len) ? ENC[(v >> 6) & 0x3F] : '=';
        out[o++] = '=';
    }
    out[o] = '\0';
    return o;
}

size_t base64_decode(const char *in, size_t len, unsigned char *out, size_t out_cap) {
    dec_init();
    unsigned acc = 0;
    int bits = 0;
    size_t o = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)in[i];
        unsigned char d = DEC[c];
        if (d == 0xFE) continue;          /* whitespace */
        if (d == 0x40) break;              /* '=' padding — stop */
        if (d == 0xFF) return (size_t)-1;  /* illegal */
        acc = (acc << 6) | d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= out_cap) return (size_t)-1;
            out[o++] = (unsigned char)((acc >> bits) & 0xFF);
        }
    }
    return o;
}
