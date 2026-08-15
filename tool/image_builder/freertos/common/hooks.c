/* Failure hooks every app needs: configASSERT and the stack-overflow
 * check both report over the console and power the machine down, so a
 * failing image exits the emulator instead of hanging it.
 */

#include "FreeRTOS.h"
#include "task.h"

#include "htif.h"

void vAssertCalled(const char *file, int line)
{
    taskDISABLE_INTERRUPTS();
    htif_puts("ASSERT at ");
    htif_puts(file);
    htif_putchar(':');
    htif_put_dec((uint64_t)line);
    htif_putchar('\n');
    htif_poweroff();
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *task_name)
{
    (void)task;
    taskDISABLE_INTERRUPTS();
    htif_puts("STACK OVERFLOW in ");
    htif_puts(task_name);
    htif_putchar('\n');
    htif_poweroff();
}
