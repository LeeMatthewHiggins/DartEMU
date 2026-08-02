/* Harness configuration, from environment variables and command line.
 *
 * Secrets stay on the host: the API key is never written to the transcript
 * and never reaches the guest.
 */
#ifndef HARNESS_CONFIG_H
#define HARNESS_CONFIG_H

#include <stdbool.h>
#include <stddef.h>

typedef enum { NETWORK_NONE, NETWORK_FULL } NetworkMode;

typedef struct {
    char *api_url;
    char *api_key;
    char *model;

    long max_agent_steps;
    long max_task_seconds;
    long default_command_timeout_ms;
    size_t max_command_output_bytes;

    /* Attach to an existing serial device instead of spawning an emulator. */
    char *guest_serial_device;

    char *emulator_command; /* how to start the emulator */
    char *base_disk_image;
    char *task_disk_path;
    char *bios_path;
    char *kernel_path;
    char *cmdline;
    long memory_mb;

    char *transcript_path;
    char *artifact_output_path;
    NetworkMode network_mode;

    char *task; /* the prompt given to the model */
    bool keep_task_disk;
    bool verbose;
} Config;

void config_init(Config *config);
void config_free(Config *config);

/* Fills config from the environment, then the command line. Returns false and
 * prints the reason when the result is unusable. */
bool config_load(Config *config, int argc, char **argv);

void config_print_usage(const char *program);

const char *config_network_mode_name(NetworkMode mode);

#endif /* HARNESS_CONFIG_H */
