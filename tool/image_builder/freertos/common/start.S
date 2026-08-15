/* Entry point for the FreeRTOS image.
 *
 * The emulator's boot trampoline jumps to the start of RAM (0x80000000)
 * with a0 = hartid and a1 = device-tree address. FreeRTOS needs neither;
 * this stub sets up the global pointer and a boot stack, zeroes .bss and
 * calls main, which never returns.
 */

    .section .init
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    /* The FreeRTOS RISC-V port leaves installing its trap handler to the
     * startup code. */
    la      t0, freertos_risc_v_trap_handler
    csrw    mtvec, t0

    la      t0, __bss_start
    la      t1, __bss_end
clear_bss:
    bgeu    t0, t1, bss_done
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       clear_bss
bss_done:
    call    main

hang:
    wfi
    j       hang
