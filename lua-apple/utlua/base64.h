//
//  base64.h — declarations for base64.c (ISC/IBM implementation in .c)
//  LuanMac / OpenLuan (MIT for this header)
//

#ifndef LUAN_BASE64_H
#define LUAN_BASE64_H
#include <sys/types.h>
#include <resolv.h>

int b64_ntop(u_char const *src, size_t srclength, char *target, size_t targsize);
int b64_pton(char const *src, u_char *target, size_t targsize);

#endif
