#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"

static const long DEFAULT_MAX_STEPS = 40;
static const long DEFAULT_MAX_TASK_SECONDS = 1800;
static const long DEFAULT_COMMAND_TIMEOUT_MS = 120000;
static const size_t DEFAULT_MAX_OUTPUT_BYTES = 32768;
static const long DEFAULT_MEMORY_MB = 256;
static const char *const DEFAULT_API_URL =
    "https://api.openai.com/v1/chat/completions";
static const char *const DEFAULT_EMULATOR = "dart run bin/dart_emu.dart run";
static const char *const DEFAULT_TRANSCRIPT = "transcript.jsonl";
/* The guest needs a root device and a console; without these the kernel
   boots and then panics looking for a filesystem. */
static const char *const DEFAULT_CMDLINE = "console=hvc0 root=/dev/vda rw";

static char *dup_or_null(const char *text) {
    return text != NULL ? strdup(text) : NULL;
}

static void replace(char **slot, const char *text) {
    free(*slot);
    *slot = dup_or_null(text);
}

static void from_env(char **slot, const char *name) {
    const char *value = getenv(name);
    if (value != NULL && value[0] != '\0') {
        replace(slot, value);
    }
}

static void long_from_env(long *slot, const char *name) {
    const char *value = getenv(name);
    if (value != NULL && value[0] != '\0') {
        *slot = strtol(value, NULL, 10);
    }
}

void config_init(Config *config) {
    memset(config, 0, sizeof(*config));
    config->api_url = strdup(DEFAULT_API_URL);
    config->model = strdup("gpt-4o-mini");
    config->max_agent_steps = DEFAULT_MAX_STEPS;
    config->max_task_seconds = DEFAULT_MAX_TASK_SECONDS;
    config->default_command_timeout_ms = DEFAULT_COMMAND_TIMEOUT_MS;
    config->max_command_output_bytes = DEFAULT_MAX_OUTPUT_BYTES;
    config->emulator_command = strdup(DEFAULT_EMULATOR);
    config->transcript_path = strdup(DEFAULT_TRANSCRIPT);
    config->cmdline = strdup(DEFAULT_CMDLINE);
    config->memory_mb = DEFAULT_MEMORY_MB;
    config->network_mode = NETWORK_NONE;
}

void config_free(Config *config) {
    free(config->api_url);
    free(config->api_key);
    free(config->model);
    free(config->guest_serial_device);
    free(config->emulator_command);
    free(config->base_disk_image);
    free(config->task_disk_path);
    free(config->bios_path);
    free(config->kernel_path);
    free(config->cmdline);
    free(config->transcript_path);
    free(config->artifact_output_path);
    free(config->task);
    memset(config, 0, sizeof(*config));
}

const char *config_network_mode_name(NetworkMode mode) {
    return mode == NETWORK_FULL ? "full" : "none";
}

void config_print_usage(const char *program) {
    fprintf(stderr,
            "Usage: %s --task <text> [options]\n"
            "       %s --interactive [options]      (AgentEMU: an AI "
            "terminal)\n"
            "\n"
            "Runs an LLM agent with one tool — a shell inside a disposable\n"
            "emulated guest. The emulator is the security boundary; this\n"
            "harness applies no command filtering of any kind.\n"
            "\n"
            "Required:\n"
            "  --task <text>            Task description for the model\n"
            "  --base-disk <path>       Base rootfs image (copied, never "
            "written)\n"
            "  --kernel <path>          Guest kernel image\n"
            "\n"
            "Options:\n"
            "  --task-file <path>       Read the task from a file\n"
            "  --bios <path>            Guest bootloader (BBL)\n"
            "  --cmdline <text>         Kernel command line\n"
            "  --memory <mb>            Guest RAM (default %ld)\n"
            "  --task-disk <path>       Where to put the writable copy\n"
            "  --keep-task-disk         Do not delete the task disk at exit\n"
            "  --serial <device>        Attach to a serial device instead of\n"
            "                           starting an emulator\n"
            "  --emulator <command>     How to start the emulator\n"
            "  --api-url <url>          OpenAI-compatible endpoint\n"
            "  --model <name>           Model name\n"
            "  --max-steps <n>          Agent step limit (default %ld)\n"
            "  --max-seconds <n>        Task wall-clock limit (default %ld)\n"
            "  --command-timeout <ms>   Default per-command timeout (default "
            "%ld)\n"
            "  --max-output <bytes>     Per-stream output cap (default %zu)\n"
            "  --network <none|full>    Guest network mode (default none)\n"
            "  --transcript <path>      JSONL transcript (default %s)\n"
            "  --artifacts <path>       Where to export the result\n"
            "  --interactive            AgentEMU: talk to the agent instead\n"
            "                           of running one task and exiting\n"
            "  --verbose                Log progress to stderr\n"
            "  --help                   Show this message\n"
            "\n"
            "Environment: LLM_API_URL, LLM_API_KEY, LLM_MODEL,\n"
            "  MAX_AGENT_STEPS, MAX_TASK_SECONDS, DEFAULT_COMMAND_TIMEOUT_MS,\n"
            "  MAX_COMMAND_OUTPUT_BYTES, GUEST_SERIAL_DEVICE, BASE_DISK_IMAGE,\n"
            "  TASK_DISK_PATH, TRANSCRIPT_PATH, ARTIFACT_OUTPUT_PATH,\n"
            "  NETWORK_MODE\n",
            program, program, DEFAULT_MEMORY_MB, DEFAULT_MAX_STEPS,
            DEFAULT_MAX_TASK_SECONDS, DEFAULT_COMMAND_TIMEOUT_MS,
            DEFAULT_MAX_OUTPUT_BYTES, DEFAULT_TRANSCRIPT);
}

static void load_environment(Config *config) {
    from_env(&config->api_url, "LLM_API_URL");
    from_env(&config->api_key, "LLM_API_KEY");
    from_env(&config->model, "LLM_MODEL");
    from_env(&config->guest_serial_device, "GUEST_SERIAL_DEVICE");
    from_env(&config->base_disk_image, "BASE_DISK_IMAGE");
    from_env(&config->task_disk_path, "TASK_DISK_PATH");
    from_env(&config->transcript_path, "TRANSCRIPT_PATH");
    from_env(&config->artifact_output_path, "ARTIFACT_OUTPUT_PATH");

    long_from_env(&config->max_agent_steps, "MAX_AGENT_STEPS");
    long_from_env(&config->max_task_seconds, "MAX_TASK_SECONDS");
    long_from_env(&config->default_command_timeout_ms,
                  "DEFAULT_COMMAND_TIMEOUT_MS");

    const char *output = getenv("MAX_COMMAND_OUTPUT_BYTES");
    if (output != NULL && output[0] != '\0') {
        config->max_command_output_bytes = (size_t)strtoul(output, NULL, 10);
    }
    const char *network = getenv("NETWORK_MODE");
    if (network != NULL && strcmp(network, "full") == 0) {
        config->network_mode = NETWORK_FULL;
    }
}

static bool read_file(const char *path, char **out) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return false;
    }
    Buffer contents;
    buffer_init(&contents);
    char chunk[4096];
    size_t got;
    while ((got = fread(chunk, 1, sizeof(chunk), file)) > 0) {
        if (!buffer_append(&contents, chunk, got)) {
            buffer_free(&contents);
            fclose(file);
            return false;
        }
    }
    fclose(file);
    *out = contents.data != NULL ? contents.data : calloc(1, 1);
    return true;
}

/* Returns the option's value, or NULL when the flag was the last argument. */
static const char *value_of(int argc, char **argv, int *i) {
    if (*i + 1 >= argc) {
        fprintf(stderr, "harness: %s needs a value\n", argv[*i]);
        return NULL;
    }
    *i += 1;
    return argv[*i];
}

bool config_load(Config *config, int argc, char **argv) {
    load_environment(config);

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char *value = NULL;

#define TAKE(target)                             \
    do {                                         \
        value = value_of(argc, argv, &i);        \
        if (value == NULL) return false;         \
        replace(&config->target, value);         \
    } while (0)

#define TAKE_LONG(target)                        \
    do {                                         \
        value = value_of(argc, argv, &i);        \
        if (value == NULL) return false;         \
        config->target = strtol(value, NULL, 10);\
    } while (0)

        if (strcmp(arg, "--task") == 0) {
            TAKE(task);
        } else if (strcmp(arg, "--task-file") == 0) {
            value = value_of(argc, argv, &i);
            if (value == NULL) return false;
            char *contents = NULL;
            if (!read_file(value, &contents)) {
                fprintf(stderr, "harness: cannot read task file %s\n", value);
                return false;
            }
            free(config->task);
            config->task = contents;
        } else if (strcmp(arg, "--base-disk") == 0) {
            TAKE(base_disk_image);
        } else if (strcmp(arg, "--task-disk") == 0) {
            TAKE(task_disk_path);
        } else if (strcmp(arg, "--kernel") == 0) {
            TAKE(kernel_path);
        } else if (strcmp(arg, "--bios") == 0) {
            TAKE(bios_path);
        } else if (strcmp(arg, "--cmdline") == 0) {
            TAKE(cmdline);
        } else if (strcmp(arg, "--serial") == 0) {
            TAKE(guest_serial_device);
        } else if (strcmp(arg, "--emulator") == 0) {
            TAKE(emulator_command);
        } else if (strcmp(arg, "--api-url") == 0) {
            TAKE(api_url);
        } else if (strcmp(arg, "--model") == 0) {
            TAKE(model);
        } else if (strcmp(arg, "--transcript") == 0) {
            TAKE(transcript_path);
        } else if (strcmp(arg, "--artifacts") == 0) {
            TAKE(artifact_output_path);
        } else if (strcmp(arg, "--memory") == 0) {
            TAKE_LONG(memory_mb);
        } else if (strcmp(arg, "--max-steps") == 0) {
            TAKE_LONG(max_agent_steps);
        } else if (strcmp(arg, "--max-seconds") == 0) {
            TAKE_LONG(max_task_seconds);
        } else if (strcmp(arg, "--command-timeout") == 0) {
            TAKE_LONG(default_command_timeout_ms);
        } else if (strcmp(arg, "--max-output") == 0) {
            value = value_of(argc, argv, &i);
            if (value == NULL) return false;
            config->max_command_output_bytes = (size_t)strtoul(value, NULL, 10);
        } else if (strcmp(arg, "--network") == 0) {
            value = value_of(argc, argv, &i);
            if (value == NULL) return false;
            if (strcmp(value, "full") == 0) {
                config->network_mode = NETWORK_FULL;
            } else if (strcmp(value, "none") == 0) {
                config->network_mode = NETWORK_NONE;
            } else {
                fprintf(stderr,
                        "harness: network mode must be none or full "
                        "(proxy and allowlist are not in this MVP)\n");
                return false;
            }
        } else if (strcmp(arg, "--keep-task-disk") == 0) {
            config->keep_task_disk = true;
        } else if (strcmp(arg, "--interactive") == 0 ||
                   strcmp(arg, "-i") == 0) {
            config->interactive = true;
        } else if (strcmp(arg, "--verbose") == 0) {
            config->verbose = true;
        } else if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            config_print_usage(argv[0]);
            return false;
        } else {
            fprintf(stderr, "harness: unknown option %s\n", arg);
            return false;
        }

#undef TAKE
#undef TAKE_LONG
    }

    if (!config->interactive &&
        (config->task == NULL || config->task[0] == '\0')) {
        fprintf(stderr,
                "harness: --task or --task-file is required "
                "(or use --interactive)\n");
        return false;
    }
    /* Interactive sessions ask for the key rather than refusing to start:
     * being asked to log in is the first thing a machine should do. */
    if (!config->interactive &&
        (config->api_key == NULL || config->api_key[0] == '\0')) {
        fprintf(stderr, "harness: LLM_API_KEY is not set\n");
        return false;
    }
    if (config->guest_serial_device == NULL) {
        if (config->kernel_path == NULL) {
            fprintf(stderr,
                    "harness: --kernel is required unless --serial is used\n");
            return false;
        }
        if (config->base_disk_image == NULL) {
            fprintf(stderr,
                    "harness: --base-disk is required unless --serial is "
                    "used\n");
            return false;
        }
    }
    if (config->max_command_output_bytes == 0) {
        fprintf(stderr, "harness: --max-output must be greater than zero\n");
        return false;
    }
    return true;
}
