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

/* Called as each command starts and finishes, so an interactive front end
 * can show the work rather than sitting silent. */
typedef void (*OnToolCallFn)(void *user, const char *command, const char *cwd);
typedef void (*OnToolResultFn)(void *user, const ExecResult *result,
                               long duration_ms);

typedef struct {
    LlmCompleteFn complete;
    GuestExecFn exec;
    OnToolCallFn on_tool_call;
    OnToolResultFn on_tool_result;
    void *user;
} AgentHooks;

/* A conversation that outlives a single question.
 *
 * One-shot runs create one, ask once and discard it. An interactive session
 * keeps it, so the model remembers what it already did in the guest. */
typedef struct {
    Conversation conversation;
    long steps_used;
    long started_seconds;
} AgentSession;

/* Seeds the system prompt. The task is not added here: each question is
 * supplied to agent_session_ask. */
void agent_session_init(AgentSession *session);
void agent_session_free(AgentSession *session);

/* Asks one question and works until the model answers or a limit is hit.
 * The step and time budgets in config apply to the session as a whole, so a
 * long conversation cannot outlast them. */
AgentOutcome agent_session_ask(AgentSession *session, const Config *config,
                               Guest *guest, Transcript *transcript,
                               const AgentHooks *hooks,
                               const volatile sig_atomic_t *interrupted,
                               const char *question);

const char *agent_stop_reason_name(AgentStopReason reason);

void agent_outcome_free(AgentOutcome *outcome);

/* Runs the loop to completion. Uses the real LLM and guest when hooks is
 * NULL. Set interrupted (from a signal handler) to stop between steps. */
AgentOutcome agent_run(const Config *config, Guest *guest,
                       Transcript *transcript, const AgentHooks *hooks,
                       const volatile sig_atomic_t *interrupted);

#endif /* HARNESS_AGENT_H */
