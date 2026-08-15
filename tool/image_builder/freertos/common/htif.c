#include "htif.h"

/* The HTIF device latches two 32-bit halves of the tohost register and
 * acts on each 32-bit store. The low word must therefore be written
 * before the high word: the command byte lives in the high word, so the
 * write that completes the pair is the one that carries the command.
 */

#define HTIF_BASE 0x40008000UL

#define TOHOST_DEVICE_CONSOLE (1UL << 24)
#define TOHOST_CMD_PUTCHAR (1UL << 16)
#define TOHOST_POWEROFF 1U

static volatile uint32_t *const tohost_lo = (volatile uint32_t *)HTIF_BASE;
static volatile uint32_t *const tohost_hi =
    (volatile uint32_t *)(HTIF_BASE + 4);

void htif_putchar(char c)
{
    *tohost_lo = (uint8_t)c;
    *tohost_hi = TOHOST_DEVICE_CONSOLE | TOHOST_CMD_PUTCHAR;
}

void htif_puts(const char *s)
{
    while (*s != '\0') {
        if (*s == '\n') {
            htif_putchar('\r');
        }
        htif_putchar(*s++);
    }
}

void htif_put_dec(uint64_t value)
{
    char digits[20];
    int n = 0;

    do {
        digits[n++] = (char)('0' + (value % 10));
        value /= 10;
    } while (value != 0);

    while (n > 0) {
        htif_putchar(digits[--n]);
    }
}

void htif_poweroff(void)
{
    *tohost_hi = 0;
    *tohost_lo = TOHOST_POWEROFF;
    for (;;) {
        __asm__ volatile("wfi");
    }
}
