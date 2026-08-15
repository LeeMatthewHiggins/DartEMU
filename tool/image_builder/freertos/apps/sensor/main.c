/* A small embedded-style firmware: a sensor task samples a simulated
 * temperature at a fixed rate and pushes readings through a queue to a
 * logger task, which prints them over the HTIF console. When the sample
 * budget is spent the logger prints a summary and powers the machine
 * down, so a scripted run exits cleanly.
 */

#include <stdint.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"

#include "htif.h"

enum {
    kSensorPeriodMs = 100,
    kSampleCount = 25,
    kQueueDepth = 8,
    kSensorPriority = 2,
    kLoggerPriority = 1,
    kTaskStackWords = 512,
};

enum {
    kBaseCentiCelsius = 2150,
    kSwingCentiCelsius = 400,
};

typedef struct {
    TickType_t tick;
    int32_t centi_celsius;
} SensorReading;

static QueueHandle_t reading_queue;
static SemaphoreHandle_t console_mutex;

static uint32_t next_noise(void)
{
    static uint32_t state = 0x2CF5A7u;
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

static int32_t sample_temperature(void)
{
    const int32_t swing = (int32_t)(next_noise() % (2 * kSwingCentiCelsius));
    return kBaseCentiCelsius - kSwingCentiCelsius + swing;
}

static void print_temp(int32_t centi_celsius)
{
    htif_put_dec((uint64_t)centi_celsius / 100);
    htif_putchar('.');
    htif_put_dec((uint64_t)centi_celsius % 100 / 10);
    htif_putchar('C');
}

static void print_reading(const SensorReading *reading)
{
    xSemaphoreTake(console_mutex, portMAX_DELAY);
    htif_puts("[logger] t=");
    htif_put_dec(reading->tick * portTICK_PERIOD_MS);
    htif_puts("ms temp=");
    print_temp(reading->centi_celsius);
    htif_putchar('\n');
    xSemaphoreGive(console_mutex);
}

static void sensor_task(void *parameters)
{
    (void)parameters;
    TickType_t wake_time = xTaskGetTickCount();

    for (int i = 0; i < kSampleCount; i++) {
        vTaskDelayUntil(&wake_time, pdMS_TO_TICKS(kSensorPeriodMs));
        const SensorReading reading = {
            .tick = xTaskGetTickCount(),
            .centi_celsius = sample_temperature(),
        };
        xQueueSend(reading_queue, &reading, portMAX_DELAY);
    }

    const SensorReading sentinel = {.tick = 0, .centi_celsius = -1};
    xQueueSend(reading_queue, &sentinel, portMAX_DELAY);
    vTaskDelete(NULL);
}

static void logger_task(void *parameters)
{
    (void)parameters;
    int32_t min = INT32_MAX;
    int32_t max = 0;
    int64_t sum = 0;
    int count = 0;

    for (;;) {
        SensorReading reading;
        xQueueReceive(reading_queue, &reading, portMAX_DELAY);
        if (reading.centi_celsius < 0) {
            break;
        }
        count++;
        sum += reading.centi_celsius;
        min = reading.centi_celsius < min ? reading.centi_celsius : min;
        max = reading.centi_celsius > max ? reading.centi_celsius : max;
        print_reading(&reading);
    }

    htif_puts("[logger] done: ");
    htif_put_dec((uint64_t)count);
    htif_puts(" samples, min=");
    print_temp(min);
    htif_puts(" max=");
    print_temp(max);
    htif_puts(" avg=");
    print_temp((int32_t)(sum / count));
    htif_puts("\n[logger] powering off\n");
    htif_poweroff();
}

int main(void)
{
    htif_puts("\nFreeRTOS ");
    htif_puts(tskKERNEL_VERSION_NUMBER);
    htif_puts(" on DartEMU riscv64\n");

    reading_queue = xQueueCreate(kQueueDepth, sizeof(SensorReading));
    console_mutex = xSemaphoreCreateMutex();
    configASSERT(reading_queue != NULL && console_mutex != NULL);

    xTaskCreate(sensor_task, "sensor", kTaskStackWords, NULL, kSensorPriority,
                NULL);
    xTaskCreate(logger_task, "logger", kTaskStackWords, NULL, kLoggerPriority,
                NULL);

    vTaskStartScheduler();

    htif_puts("scheduler returned: out of heap\n");
    htif_poweroff();
}
