/* Minimal freestanding stand-in, backed by libc_shim.c. */
#ifndef SHIM_STRING_H
#define SHIM_STRING_H

#include <stddef.h>

void *memset(void *dest, int value, size_t count);
void *memcpy(void *dest, const void *src, size_t count);
void *memmove(void *dest, const void *src, size_t count);
int memcmp(const void *lhs, const void *rhs, size_t count);
size_t strlen(const char *s);

#endif
