#ifndef HTIF_H
#define HTIF_H

#include <stdint.h>

/** Writes one character to the HTIF console. */
void htif_putchar(char c);

/** Writes a NUL-terminated string, translating '\n' to "\r\n". */
void htif_puts(const char *s);

/** Writes an unsigned value in decimal. */
void htif_put_dec(uint64_t value);

/** Asks the emulator to power the machine down. Does not return. */
void htif_poweroff(void) __attribute__((noreturn));

#endif
