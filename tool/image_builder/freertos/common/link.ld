/* Links the image at the base of the emulator's RAM, where the boot
 * trampoline jumps. The output is turned into a flat binary, so the
 * section layout here is also the file layout.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M
}

BOOT_STACK_SIZE = 16K;

SECTIONS
{
    .text : {
        KEEP(*(.init))
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > RAM

    .data : {
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += BOOT_STACK_SIZE;
        __stack_top = .;
    } > RAM
}
