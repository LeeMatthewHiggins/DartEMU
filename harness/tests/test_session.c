/* AgentEMU keeps one conversation across many questions, so what the agent
 * did in the guest earlier is still in context later. */
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include "agent.h"
#include "harness_test.h"
#include "interactive.h"

static const char **g_script;
static size_t g_script_len;
static size_t g_next;
static size_t g_message_count_at_last_call;

static bool fake_complete(const Config *config, const Conversation *conversation,
                          LlmResponse *response, char **error) {
    (void)config;
    g_message_count_at_last_call = conversation->count;
    if (g_next >= g_script_len) {
        if (error != NULL) *error = strdup("the script ran out of turns");
        return false;
    }
    const char *body = g_script[g_next++];
    return llm_parse_response(body, strlen(body), response, error);
}

static size_t g_commands_run;

static void fake_exec(Guest *guest, const char *command, const char *cwd,
                      long timeout_ms, ExecResult *result) {
    (void)guest;
    (void)command;
    (void)cwd;
    (void)timeout_ms;
    exec_result_init(result);
    g_commands_run++;
    result->exit_code = 0;
    buffer_append_str(&result->stdout_text, "ok");
}

static Guest g_guest;

static void reset(const char **script, size_t len) {
    g_script = script;
    g_script_len = len;
    g_next = 0;
    g_commands_run = 0;
    g_message_count_at_last_call = 0;
    memset(&g_guest, 0, sizeof(g_guest));
    g_guest.ready = true;
    g_guest.from_guest = 1;
}

static Config make_config(long max_steps) {
    Config config;
    config_init(&config);
    config.max_agent_steps = max_steps;
    config.max_task_seconds = 600;
    return config;
}

static const char *TOOL_TURN =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":["
    "{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"shell\","
    "\"arguments\":\"{\\\"command\\\":\\\"touch /workspace/a\\\"}\"}}]}}]}";

static const char *ANSWER_ONE =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":"
    "\"Created the file.\"}}]}";

static const char *ANSWER_TWO =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":"
    "\"It is still there.\"}}]}";

static void test_conversation_survives_between_questions(void) {
    const char *script[] = {TOOL_TURN, ANSWER_ONE, ANSWER_TWO};
    reset(script, 3);

    Config config = make_config(20);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentSession session;
    agent_session_init(&session);

    AgentOutcome first =
        agent_session_ask(&session, &config, &g_guest, &transcript, &hooks,
                          NULL, "create a file");
    CHECK(first.reason == AGENT_FINAL_ANSWER, "the first question is answered");
    CHECK_STR_EQ(first.final_answer, "Created the file.",
                 "the first answer is returned");
    size_t after_first = session.conversation.count;
    agent_outcome_free(&first);

    AgentOutcome second =
        agent_session_ask(&session, &config, &g_guest, &transcript, &hooks,
                          NULL, "is it still there?");
    CHECK(second.reason == AGENT_FINAL_ANSWER,
          "the second question is answered");
    CHECK_STR_EQ(second.final_answer, "It is still there.",
                 "the second answer is returned");

    /* The point of a session: the model sees the earlier work, not a fresh
     * conversation with only the new question in it. */
    CHECK(g_message_count_at_last_call > after_first,
          "the second question is asked with the earlier turns still present");
    CHECK(session.conversation.count > after_first,
          "the conversation grows rather than resetting");
    agent_outcome_free(&second);

    agent_session_free(&session);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_the_system_prompt_is_seeded_once(void) {
    const char *script[] = {ANSWER_ONE, ANSWER_TWO};
    reset(script, 2);

    Config config = make_config(20);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentSession session;
    agent_session_init(&session);
    CHECK_LONG_EQ(session.conversation.count, 1,
                  "a new session starts with only the system prompt");

    AgentOutcome first = agent_session_ask(&session, &config, &g_guest,
                                           &transcript, &hooks, NULL, "one");
    agent_outcome_free(&first);
    AgentOutcome second = agent_session_ask(&session, &config, &g_guest,
                                            &transcript, &hooks, NULL, "two");
    agent_outcome_free(&second);

    size_t system_messages = 0;
    for (size_t i = 0; i < session.conversation.count; i++) {
        if (strstr(session.conversation.messages[i], "\"role\":\"system\"") !=
            NULL) {
            system_messages++;
        }
    }
    CHECK_LONG_EQ(system_messages, 1,
                  "the system prompt is not repeated per question");

    agent_session_free(&session);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_the_budget_spans_the_whole_session(void) {
    /* A long conversation must not outlive the step budget by resetting it
     * on every question. */
    const char *script[] = {TOOL_TURN, ANSWER_ONE, TOOL_TURN, TOOL_TURN};
    reset(script, 4);

    Config config = make_config(3);
    Transcript transcript;
    transcript_open(&transcript, NULL);
    AgentHooks hooks = {.complete = fake_complete, .exec = fake_exec};

    AgentSession session;
    agent_session_init(&session);

    AgentOutcome first = agent_session_ask(&session, &config, &g_guest,
                                           &transcript, &hooks, NULL, "one");
    CHECK(first.reason == AGENT_FINAL_ANSWER, "the first question completes");
    CHECK_LONG_EQ(session.steps_used, 2, "two steps are spent");
    agent_outcome_free(&first);

    AgentOutcome second = agent_session_ask(&session, &config, &g_guest,
                                            &transcript, &hooks, NULL, "two");
    CHECK(second.reason == AGENT_STEP_LIMIT,
          "the remaining budget is what is left, not a fresh allowance");
    CHECK_LONG_EQ(session.steps_used, 3, "the session stops at the limit");
    agent_outcome_free(&second);

    agent_session_free(&session);
    transcript_close(&transcript);
    config_free(&config);
}

static void test_an_api_key_already_present_is_not_asked_for(void) {
    Config config;
    config_init(&config);
    config.api_key = strdup("sk-existing");
    CHECK(interactive_prompt_for_api_key(&config),
          "an existing key is accepted without prompting");
    CHECK_STR_EQ(config.api_key, "sk-existing", "the key is left alone");
    config_free(&config);
}

int main(void) {
    test_conversation_survives_between_questions();
    test_the_system_prompt_is_seeded_once();
    test_the_budget_spans_the_whole_session();
    test_an_api_key_already_present_is_not_asked_for();
    TEST_REPORT();
}
