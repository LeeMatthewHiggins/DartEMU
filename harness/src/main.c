#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agent.h"
#include "config.h"
#include "guest.h"
#include "llm.h"
#include "transcript.h"

enum { EXIT_TASK_INCOMPLETE = 2, EXIT_SETUP_FAILED = 3 };

static volatile sig_atomic_t g_interrupted = 0;

static void on_interrupt(int signal_number) {
    (void)signal_number;
    g_interrupted = 1;
}

int main(int argc, char **argv) {
    Config config;
    config_init(&config);
    if (!config_load(&config, argc, argv)) {
        config_free(&config);
        return EXIT_SETUP_FAILED;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_interrupt;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    /* A guest that closes mid-write must not kill the harness. */
    signal(SIGPIPE, SIG_IGN);

    if (!llm_global_init()) {
        fprintf(stderr, "harness: could not initialise the HTTP client\n");
        config_free(&config);
        return EXIT_SETUP_FAILED;
    }

    Transcript transcript;
    if (!transcript_open(&transcript, config.transcript_path)) {
        fprintf(stderr, "harness: cannot write the transcript to %s\n",
                config.transcript_path);
        llm_global_cleanup();
        config_free(&config);
        return EXIT_SETUP_FAILED;
    }

    Guest guest;
    guest_init(&guest, &config);

    if (config.verbose) {
        fprintf(stderr, "[harness] starting the guest (network %s)\n",
                config_network_mode_name(config.network_mode));
    }

    int status = EXIT_SUCCESS;
    if (!guest_start(&guest)) {
        fprintf(stderr, "harness: the guest did not start: %s\n",
                guest_last_error(&guest));
        transcript_write_error(&transcript, 0, guest_last_error(&guest));
        status = EXIT_SETUP_FAILED;
    } else {
        transcript_write_start(&transcript, config.task, config.model,
                               config_network_mode_name(config.network_mode),
                               config.max_agent_steps, config.max_task_seconds);

        AgentOutcome outcome =
            agent_run(&config, &guest, &transcript, NULL, &g_interrupted);

        /* Export before shutdown, while the guest can still be asked. */
        if (config.artifact_output_path != NULL) {
            if (guest_export_artifacts(&guest, config.artifact_output_path)) {
                if (config.verbose) {
                    fprintf(stderr, "[harness] workspace exported to %s\n",
                            config.artifact_output_path);
                }
            } else {
                fprintf(stderr, "harness: could not export the workspace: %s\n",
                        guest_last_error(&guest));
            }
        }

        transcript_write_end(&transcript, agent_stop_reason_name(outcome.reason),
                             outcome.steps_used, outcome.elapsed_seconds,
                             outcome.final_answer);

        if (outcome.reason == AGENT_FINAL_ANSWER) {
            if (outcome.final_answer != NULL) {
                printf("%s\n", outcome.final_answer);
            }
        } else {
            fprintf(stderr, "harness: stopped without a final answer (%s)\n",
                    agent_stop_reason_name(outcome.reason));
            status = EXIT_TASK_INCOMPLETE;
        }

        if (config.verbose) {
            fprintf(stderr, "[harness] %ld steps, %lds, reason %s\n",
                    outcome.steps_used, outcome.elapsed_seconds,
                    agent_stop_reason_name(outcome.reason));
        }
        agent_outcome_free(&outcome);
    }

    guest_shutdown(&guest);
    guest_free(&guest);
    transcript_close(&transcript);
    llm_global_cleanup();
    config_free(&config);
    return status;
}
