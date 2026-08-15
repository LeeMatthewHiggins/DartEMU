#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* Configuration for the DartEMU machine: a single hart with a CLINT at
 * the SiFive-standard addresses and a 10 MHz real-time clock. The RISC-V
 * port drives the tick from mtime/mtimecmp directly, so the "CPU clock"
 * here is the RTC frequency, not an instruction rate.
 */

#define configMTIME_BASE_ADDRESS (0x2000000UL + 0xBFF8UL)
#define configMTIMECMP_BASE_ADDRESS (0x2000000UL + 0x4000UL)
#define configCPU_CLOCK_HZ (10000000UL)
/* 100 Hz keeps tick-interrupt overhead low on an interpreted CPU. */
#define configTICK_RATE_HZ ((TickType_t)100)

#define configISR_STACK_SIZE_WORDS (512)

#define configUSE_PREEMPTION 1
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0
#define configMAX_PRIORITIES (5)
#define configMINIMAL_STACK_SIZE ((unsigned short)256)
#define configTOTAL_HEAP_SIZE ((size_t)(64 * 1024))
#define configMAX_TASK_NAME_LEN (16)
#define configTICK_TYPE_WIDTH_IN_BITS TICK_TYPE_WIDTH_32_BITS
#define configIDLE_SHOULD_YIELD 1
#define configUSE_MUTEXES 1
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configSUPPORT_STATIC_ALLOCATION 0
#define configUSE_TIMERS 0
#define configCHECK_FOR_STACK_OVERFLOW 2

#define INCLUDE_vTaskDelay 1
#define INCLUDE_xTaskDelayUntil 1
#define INCLUDE_vTaskDelete 1
#define INCLUDE_vTaskSuspend 1
#define INCLUDE_uxTaskPriorityGet 1
#define INCLUDE_vTaskPrioritySet 1

void vAssertCalled(const char *file, int line);
#define configASSERT(x) \
    do { \
        if ((x) == 0) { \
            vAssertCalled(__FILE__, __LINE__); \
        } \
    } while (0)

#endif
