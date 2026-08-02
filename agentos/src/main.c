#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentos.h"

static const char *const USAGE =
    "usage: agentos [options]\n"
    "  --gateway IP       where the host proxy listens (default 10.0.2.2)\n"
    "  --host NAME        named upstream to reach (default llm.local)\n"
    "  --port N           port on that upstream (default 80)\n"
    "  --path PATH        request path (default /v1/chat/completions)\n"
    "  --model NAME       model to ask for\n"
    "  --key PLACEHOLDER  ${NAME} the host substitutes; never a real key\n"
    "  --max-steps N      tool calls allowed per question\n"
    "  --max-output N     bytes kept from each command\n"
    "  --timeout MS       how long a command may run\n"
    "\n"
    "Every option can also be given as an environment variable:\n"
    "AGENTOS_GATEWAY, AGENTOS_HOST, AGENTOS_PORT, AGENTOS_PATH, AGENTOS_MODEL,\n"
    "AGENTOS_KEY, AGENTOS_MAX_STEPS, AGENTOS_MAX_OUTPUT,\n"
    "AGENTOS_TIMEOUT_MS.\n";

static void replace(char **field, const char *value) {
    free(*field);
    *field = strdup(value);
}

static void apply_environment(AgentConfig *config) {
    const char *value;
    if ((value = getenv("AGENTOS_GATEWAY")) != NULL) {
        replace(&config->gateway, value);
    }
    if ((value = getenv("AGENTOS_HOST")) != NULL) replace(&config->host, value);
    if ((value = getenv("AGENTOS_PATH")) != NULL) replace(&config->path, value);
    if ((value = getenv("AGENTOS_MODEL")) != NULL) {
        replace(&config->model, value);
    }
    if ((value = getenv("AGENTOS_KEY")) != NULL) {
        replace(&config->key_placeholder, value);
    }
    if ((value = getenv("AGENTOS_PORT")) != NULL) config->port = atoi(value);
    if ((value = getenv("AGENTOS_MAX_STEPS")) != NULL) {
        config->max_steps = atol(value);
    }
    if ((value = getenv("AGENTOS_MAX_OUTPUT")) != NULL) {
        config->max_output = (size_t)atol(value);
    }
    if ((value = getenv("AGENTOS_TIMEOUT_MS")) != NULL) {
        config->command_timeout_ms = atol(value);
    }
}

/* Returns false when the arguments ask for help or make no sense. */
static bool apply_arguments(AgentConfig *config, int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *flag = argv[i];
        bool has_value = i + 1 < argc;
        const char *value = has_value ? argv[i + 1] : NULL;

        if (strcmp(flag, "--help") == 0 || strcmp(flag, "-h") == 0) {
            return false;
        }
        if (!has_value) {
            fprintf(stderr, "%s needs a value\n", flag);
            return false;
        }

        if (strcmp(flag, "--gateway") == 0) {
            replace(&config->gateway, value);
        } else if (strcmp(flag, "--host") == 0) {
            replace(&config->host, value);
        } else if (strcmp(flag, "--path") == 0) {
            replace(&config->path, value);
        } else if (strcmp(flag, "--model") == 0) {
            replace(&config->model, value);
        } else if (strcmp(flag, "--key") == 0) {
            replace(&config->key_placeholder, value);
        } else if (strcmp(flag, "--port") == 0) {
            config->port = atoi(value);
        } else if (strcmp(flag, "--max-steps") == 0) {
            config->max_steps = atol(value);
        } else if (strcmp(flag, "--max-output") == 0) {
            config->max_output = (size_t)atol(value);
        } else if (strcmp(flag, "--timeout") == 0) {
            config->command_timeout_ms = atol(value);
        } else {
            fprintf(stderr, "unknown option %s\n", flag);
            return false;
        }
        i++;
    }
    return true;
}

int main(int argc, char **argv) {
    /* A command that dies with its pipe half-read must not take the agent
     * with it. */
    signal(SIGPIPE, SIG_IGN);

    AgentConfig config;
    agent_config_init(&config);
    apply_environment(&config);
    if (!apply_arguments(&config, argc, argv)) {
        fputs(USAGE, stderr);
        agent_config_free(&config);
        return 2;
    }

    printf("AgentOS — an emulated machine you talk to.\n");
    printf("Model %s, through %s. Type what you want done.\n\n", config.model,
           config.host);
    fflush(stdout);

    int status = agent_main(&config);
    agent_config_free(&config);
    return status;
}
