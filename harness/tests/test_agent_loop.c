/* Drives the agent loop against a scripted model and a fake guest, so every
 * termination condition is exercised without a network or an emulator. */
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include "agent.h"
#include "harness_test.h"

/* ------------------------------------------------------------ fake model */

typedef struct {
    const char **bodies; /* one chat completions body per turn */
    size_t count;
    size_t next;
    bool fail_always;
    size_t calls;
} FakeModel;

static FakeModel g_model;

static bool fake_complete(const Config *config, const Conversation *conversation,
                          LlmResponse *response, char **error) {
    (void)config;
    (void)conversation;
    g_model.calls++;
    if (g_model.fail_always) {
        if (error != NULL) *error = strdup("the API is unreachable");
        return false;
    }
    if (g_model.next >= g_model.count) {
        if (error != NULL) *error = strdup("the script ran out of turns");
        return false;
    }
    const char *body = g_model.bodies[g_model.next++];
    return llm_parse_response(body, strlen(body), response, error);
}

/* ------------------------------------------------------------ fake guest */

typedef struct {
    char commands[16][512];
    size_t count;
    bool alive;
    int exit_code;
} FakeGuest;

static FakeGuest g_guest;

static void fake_exec(Guest *guest, const char *command, const char *cwd,
                      long timeout_ms, ExecResult *result) {
    (void)guest;
    (void)cwd;
    (void)timeout_ms;
    exec_result_init(result);
    if (g_guest.count < 16) {
        snprintf(g_guest.commands[g_guest.count], 512, "%s", command);
    }
    g_guest.count++;
    if (!g_guest.alive) {
        exec_result_fail(result, "the guest is gone");
        return;
    }
    result->exit_code = g_guest.exit_code;
    buffer_append_str(&result->stdout_text, "ok");
}

/* guest_is_alive reads the real struct, so keep it consistent. */
static Guest g_guest_handle;

static void reset(void) {
    memset(&g_model, 0, sizeof(g_model));
    memset(&g_guest, 0, sizeof(g_guest));
    g_guest.alive = true;
    memset(&g_guest_handle, 0, sizeof(g_guest_handle));
    g_guest_handle.ready = true;
    g_guest_handle.from_guest = 1;
}

static Config make_config(long max_steps, long max_seconds) {
    Config config;
    config_init(&config);
    free(config.task);
    config.task = strdup("fix the failing tests");
    config.max_agent_steps = max_steps;
    config.max_task_seconds = max_seconds;
    return config;
}

static const char *TOOL_TURN =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":["
    "{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\","
    "\"arguments\":\"{\\\"command\\\":\\\"make test\\\"}\"}}]}}]}";

static const char *FINAL_TURN =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":"
    "\"I fixed the off-by-one and the suite passes.\"}}]}";

/* ---------------------------------------------------------------- tests */

static void test_tool_call_then_final_answer(void) {
    reset();
    const char *script[] = {TOOL_TURN, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_FINAL_ANSWER, "loop ends on a final answer");
    CHECK_LONG_EQ(outcome.steps_used, 2, "both turns are counted");
    CHECK_LONG_EQ(g_guest.count, 1, "the tool call reached the guest");
    CHECK_STR_EQ(g_guest.commands[0], "make test",
                 "the command reached the guest unmodified");
    CHECK_STR_EQ(outcome.final_answer,
                 "I fixed the off-by-one and the suite passes.",
                 "the final answer is returned");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_step_limit_stops_the_loop(void) {
    reset();
    /* A model that only ever calls the tool must still be stopped. */
    const char *script[] = {TOOL_TURN, TOOL_TURN, TOOL_TURN, TOOL_TURN};
    g_model.bodies = script;
    g_model.count = 4;

    Config config = make_config(3, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_STEP_LIMIT, "the step limit stops the loop");
    CHECK_LONG_EQ(outcome.steps_used, 3, "no more than the limit runs");
    CHECK_LONG_EQ(g_guest.count, 3, "exactly three commands ran");
    CHECK(outcome.final_answer == NULL, "no final answer is invented");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_time_limit_stops_the_loop(void) {
    reset();
    const char *script[] = {TOOL_TURN};
    g_model.bodies = script;
    g_model.count = 1;

    /* A zero-second budget is already spent at the first check. */
    Config config = make_config(100, 0);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_TIME_LIMIT, "the wall clock stops the loop");
    CHECK_LONG_EQ(g_model.calls, 0, "no model call is made once time is up");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_api_failure_ends_the_run(void) {
    reset();
    g_model.fail_always = true;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_LLM_FAILED, "a failing API ends the run");
    CHECK_LONG_EQ(g_guest.count, 0, "no command runs when the model fails");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_lost_guest_ends_the_run(void) {
    reset();
    g_guest.alive = false;
    g_guest_handle.ready = false; /* guest_is_alive now reports false */
    const char *script[] = {TOOL_TURN, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_GUEST_LOST, "an unreachable guest ends the run");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_failing_command_does_not_end_the_run(void) {
    reset();
    g_guest.exit_code = 1; /* the command fails, the task continues */
    const char *script[] = {TOOL_TURN, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_FINAL_ANSWER,
          "a non-zero exit code is data, not a failure of the run");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_interrupt_stops_between_steps(void) {
    reset();
    const char *script[] = {TOOL_TURN, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    static volatile sig_atomic_t interrupted = 1;
    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, &interrupted);

    CHECK(outcome.reason == AGENT_INTERRUPTED, "an interrupt stops the loop");
    CHECK_LONG_EQ(g_model.calls, 0, "the interrupt is seen before the API call");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_malformed_tool_call_is_reported_to_the_model(void) {
    reset();
    /* Arguments that are not an object at all: the loop must feed the error
     * back rather than abort, so the model can correct itself. */
    static const char *BAD_TOOL_TURN =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":["
        "{\"id\":\"call_x\",\"type\":\"function\",\"function\":"
        "{\"name\":\"shell\",\"arguments\":\"not json\"}}]}}]}";
    const char *script[] = {BAD_TOOL_TURN, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_FINAL_ANSWER,
          "a malformed tool call does not end the run");
    CHECK_LONG_EQ(g_guest.count, 0, "nothing is executed for a bad call");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_unknown_tool_is_refused(void) {
    reset();
    static const char *WRONG_TOOL =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":["
        "{\"id\":\"call_y\",\"type\":\"function\",\"function\":"
        "{\"name\":\"write_file\",\"arguments\":\"{}\"}}]}}]}";
    const char *script[] = {WRONG_TOOL, FINAL_TURN};
    g_model.bodies = script;
    g_model.count = 2;

    Config config = make_config(10, 600);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentOutcome outcome =
        agent_run(&config, &g_guest_handle, &transcript, &hooks, NULL);

    CHECK(outcome.reason == AGENT_FINAL_ANSWER, "the run continues");
    CHECK_LONG_EQ(g_guest.count, 0, "only the shell tool can reach the guest");

    agent_outcome_free(&outcome);
    transcript_close(&transcript);
    config_free(&config);
}

int main(void) {
    test_tool_call_then_final_answer();
    test_step_limit_stops_the_loop();
    test_time_limit_stops_the_loop();
    test_api_failure_ends_the_run();
    test_lost_guest_ends_the_run();
    test_failing_command_does_not_end_the_run();
    test_interrupt_stops_between_steps();
    test_malformed_tool_call_is_reported_to_the_model();
    test_unknown_tool_is_refused();
    TEST_REPORT();
}
