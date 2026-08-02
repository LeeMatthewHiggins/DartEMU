/* The agent loop: model, one tool, guest, repeat until a stop condition. */
#ifndef HARNESS_AGENT_H
#define HARNESS_AGENT_H

#include <signal.h>
#include <stdbool.h>

#include "config.h"
#include "guest.h"
#include "llm.h"
#include "transcript.h"

typedef enum {
    AGENT_FINAL_ANSWER,
    AGENT_STEP_LIMIT,
    AGENT_TIME_LIMIT,
    AGENT_LLM_FAILED,
    AGENT_GUEST_LOST,
    AGENT_INTERRUPTED
} AgentStopReason;

typedef struct {
    AgentStopReason reason;
    long steps_used;
    long elapsed_seconds;
    char *final_answer; /* owned; NULL when the run stopped early */
} AgentOutcome;

/* Asks the model for the next step. Replaceable so the loop can be tested
 * without a network. */
typedef bool (*LlmCompleteFn)(const Config *config,
                              const Conversation *conversation,
                              LlmResponse *response, char **error);

/* Runs one command in the guest. Replaceable for the same reason. */
typedef void (*GuestExecFn)(Guest *guest, const char *command, const char *cwd,
                            long timeout_ms, ExecResult *result);

typedef struct {
    LlmCompleteFn complete;
    GuestExecFn exec;
} AgentHooks;

const char *agent_stop_reason_name(AgentStopReason reason);

void agent_outcome_free(AgentOutcome *outcome);

/* Runs the loop to completion. Uses the real LLM and guest when hooks is
 * NULL. Set interrupted (from a signal handler) to stop between steps. */
AgentOutcome agent_run(const Config *config, Guest *guest,
                       Transcript *transcript, const AgentHooks *hooks,
                       const volatile sig_atomic_t *interrupted);

#endif /* HARNESS_AGENT_H */
