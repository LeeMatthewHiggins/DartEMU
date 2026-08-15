/* The smallest useful FreeRTOS app: one task that says hello and powers
 * the machine down. It proves the whole chain — boot, scheduler start, a
 * context switch into a task, console output and a clean exit — and is
 * the template to copy for a new app.
 */

#include "FreeRTOS.h"
#include "task.h"

#include "htif.h"

enum {
    kHelloPriority = 1,
    kTaskStackWords = 512,
};

static void hello_task(void *parameters)
{
    (void)parameters;
    htif_puts("Hello, World from FreeRTOS ");
    htif_puts(tskKERNEL_VERSION_NUMBER);
    htif_puts(" on DartEMU riscv64!\n");
    htif_poweroff();
}

int main(void)
{
    xTaskCreate(hello_task, "hello", kTaskStackWords, NULL, kHelloPriority,
                NULL);
    vTaskStartScheduler();

    htif_puts("scheduler returned: out of heap\n");
    htif_poweroff();
}
