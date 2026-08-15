/* Minimal freestanding stand-in: the toolchain ships no bare-metal
 * sysroot, and the kernel only needs size_t and NULL from this header.
 */
#ifndef SHIM_STDLIB_H
#define SHIM_STDLIB_H

#include <stddef.h>

#endif
