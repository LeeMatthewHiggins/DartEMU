/* The kernel is built freestanding, but the compiler is still entitled to
 * emit calls to the basic memory routines, and the FreeRTOS sources use a
 * few of them directly.
 */

#include <stddef.h>

void *memset(void *dest, int value, size_t count)
{
    unsigned char *d = dest;
    while (count-- > 0) {
        *d++ = (unsigned char)value;
    }
    return dest;
}

void *memcpy(void *dest, const void *src, size_t count)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (count-- > 0) {
        *d++ = *s++;
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t count)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d < s) {
        while (count-- > 0) {
            *d++ = *s++;
        }
    } else {
        d += count;
        s += count;
        while (count-- > 0) {
            *--d = *--s;
        }
    }
    return dest;
}

int memcmp(const void *lhs, const void *rhs, size_t count)
{
    const unsigned char *a = lhs;
    const unsigned char *b = rhs;
    while (count-- > 0) {
        if (*a != *b) {
            return *a - *b;
        }
        a++;
        b++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n] != '\0') {
        n++;
    }
    return n;
}
