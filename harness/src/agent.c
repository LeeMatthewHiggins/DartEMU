#include "agent.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Tells the model what kind of place it is working in. It deliberately does
 * not tell it what it may not do: the guest is disposable and the emulator is
 * the boundary, so restraint here would only cost capability. */
static const char *const SYSTEM_PROMPT =
    "You are working inside a disposable emulated Linux machine. You have "
    "root and complete freedom: install, modify, delete or reconfigure "
    "anything. The machine is destroyed when the task ends and nothing you "
    "do can affect the host.\n"
    "\n"
    "Use the 'shell' tool to run commands. Work in /workspace unless the "
    "task says otherwise. Command output is capped, so prefer targeted "
    "commands over dumping large files.\n"
    "\n"
    "When the task is done, reply with a plain message and no tool call, "
    "explaining what you did and what you found.";

static long now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

const char *agent_stop_reason_name(AgentStopReason reason) {
    switch (reason) {
        case AGENT_FINAL_ANSWER: return "final_answer";
        case AGENT_STEP_LIMIT: return "step_limit";
        case AGENT_TIME_LIMIT: return "time_limit";
        case AGENT_LLM_FAILED: return "llm_failed";
        case AGENT_GUEST_LOST: return "guest_lost";
        case AGENT_INTERRUPTED: return "interrupted";
    }
    return "unknown";
}

void agent_outcome_free(AgentOutcome *outcome) {
    free(outcome->final_answer);
    outcome->final_answer = NULL;
}

/* Renders a result the way the model sees it: exit status first, then each
 * stream, with truncation and timeouts stated rather than implied. */
static bool format_tool_result(const ExecResult *result, Buffer *out) {
    if (result->transport_error) {
        return buffer_printf(
            out, "The command could not be run: %s",
            result->error_message != NULL ? result->error_message
                                          : "the guest transport failed");
    }
    if (!buffer_printf(out, "exit_code: %d\n", result->exit_code)) return false;
    if (result->timed_out && !buffer_append_str(out, "timed_out: true\n")) {
        return false;
    }
    if (result->stdout_text.len > 0) {
        if (!buffer_append_str(out, "\n--- stdout ---\n")) return false;
        if (!buffer_append(out, result->stdout_text.data,
                           result->stdout_text.len)) {
            return false;
        }
    }
    if (result->stderr_text.len > 0) {
        if (!buffer_append_str(out, "\n--- stderr ---\n")) return false;
        if (!buffer_append(out, result->stderr_text.data,
                           result->stderr_text.len)) {
            return false;
        }
    }
    if (result->stdout_text.len == 0 && result->stderr_text.len == 0) {
        if (!buffer_append_str(out, "\n(no output)\n")) return false;
    }
    return true;
}

static AgentOutcome finish(AgentStopReason reason, long steps, long started,
                           char *answer) {
    AgentOutcome outcome = {.reason = reason,
                            .steps_used = steps,
                            .elapsed_seconds = now_seconds() - started,
                            .final_answer = answer};
    return outcome;
}

AgentOutcome agent_run(const Config *config, Guest *guest,
                       Transcript *transcript, const AgentHooks *hooks,
                       const volatile sig_atomic_t *interrupted) {
    LlmCompleteFn complete =
        hooks != NULL && hooks->complete != NULL ? hooks->complete
                                                 : llm_complete;
    GuestExecFn exec =
        hooks != NULL && hooks->exec != NULL ? hooks->exec : guest_exec;

    Conversation conversation;
    conversation_init(&conversation);
    conversation_add_text(&conversation, "system", SYSTEM_PROMPT);
    conversation_add_text(&conversation, "user", config->task);

    const long started = now_seconds();
    long step = 0;

    for (;;) {
        if (interrupted != NULL && *interrupted != 0) {
            conversation_free(&conversation);
            return finish(AGENT_INTERRUPTED, step, started, NULL);
        }
        if (step >= config->max_agent_steps) {
            conversation_free(&conversation);
            return finish(AGENT_STEP_LIMIT, step, started, NULL);
        }
        if (now_seconds() - started >= config->max_task_seconds) {
            conversation_free(&conversation);
            return finish(AGENT_TIME_LIMIT, step, started, NULL);
        }

        step++;

        LlmResponse response;
        char *error = NULL;
        if (!complete(config, &conversation, &response, &error)) {
            transcript_write_error(transcript, step,
                                   error != NULL ? error : "the API call failed");
            if (config->verbose) {
                fprintf(stderr, "[agent] %s\n",
                        error != NULL ? error : "the API call failed");
            }
            free(error);
            conversation_free(&conversation);
            return finish(AGENT_LLM_FAILED, step, started, NULL);
        }

        if (response.raw_message != NULL) {
            conversation_add_raw(&conversation, response.raw_message);
        }
        if (response.content != NULL && response.content[0] != '\0') {
            transcript_write_assistant(transcript, step, response.content);
        }

        if (!response.has_tool_calls) {
            char *answer = response.content != NULL ? strdup(response.content)
                                                    : strdup("");
            llm_response_free(&response);
            conversation_free(&conversation);
            return finish(AGENT_FINAL_ANSWER, step, started, answer);
        }

        bool guest_lost = false;
        for (size_t i = 0; i < response.tool_call_count; i++) {
            const ToolCall *call = &response.tool_calls[i];

            if (call->decode_error != NULL) {
                /* A malformed tool call is the model's mistake to correct,
                 * not a reason to end the task. */
                transcript_write_error(transcript, step, call->decode_error);
                conversation_add_tool_result(&conversation, call->id,
                                             call->decode_error,
                                             strlen(call->decode_error));
                continue;
            }

            transcript_write_tool_call(transcript, step, call->command,
                                       call->cwd, call->timeout_ms);
            if (config->verbose) {
                fprintf(stderr, "[agent] step %ld: %s\n", step, call->command);
            }

            long start_ms = now_ms();
            ExecResult result;
            exec(guest, call->command, call->cwd, call->timeout_ms, &result);
            long duration = now_ms() - start_ms;

            transcript_write_tool_result(transcript, step, &result, duration);

            Buffer rendered;
            buffer_init(&rendered);
            if (format_tool_result(&result, &rendered)) {
                conversation_add_tool_result(&conversation, call->id,
                                             rendered.data, rendered.len);
            }
            buffer_free(&rendered);

            /* A command that fails or times out is normal. A guest that can
             * no longer be reached ends the task. */
            if (result.transport_error && !guest_is_alive(guest)) {
                guest_lost = true;
            }
            exec_result_free(&result);

            if (guest_lost) {
                break;
            }
        }

        llm_response_free(&response);

        if (guest_lost) {
            transcript_write_error(transcript, step,
                                   "the guest became unavailable");
            conversation_free(&conversation);
            return finish(AGENT_GUEST_LOST, step, started, NULL);
        }
    }
}
