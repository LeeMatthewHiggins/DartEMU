/* Requests, replies, and the promise that the machine holds no credential. */
#include <stdlib.h>
#include <string.h>

#include "agentos.h"
#include "harness_test.h"

static void test_request_carries_the_tool_and_the_messages(void) {
    AgentConfig config;
    agent_config_init(&config);
    Conversation conversation;
    conversation_init(&conversation);
    conversation_add_text(&conversation, "system", "be useful");
    conversation_add_text(&conversation, "user", "count the files");

    Buffer request;
    buffer_init(&request);
    CHECK(llm_build_request(&config, &conversation, &request),
          "the request is built");
    CHECK(strstr(request.data, "\"tools\"") != NULL, "the tool is offered");
    CHECK(strstr(request.data, "\"shell\"") != NULL, "the tool is the shell");
    CHECK(strstr(request.data, "count the files") != NULL,
          "the question is included");
    CHECK(strstr(request.data, "be useful") != NULL,
          "the system prompt is included");

    buffer_free(&request);
    conversation_free(&conversation);
    agent_config_free(&config);
}

/* A quotation mark in a question used to be able to break the request open.
 * It is escaped, so it cannot. */
static void test_awkward_input_stays_inside_its_string(void) {
    AgentConfig config;
    agent_config_init(&config);
    Conversation conversation;
    conversation_init(&conversation);
    conversation_add_text(&conversation, "user",
                          "run \"echo hi\" then\nstop\\now");

    Buffer request;
    buffer_init(&request);
    CHECK(llm_build_request(&config, &conversation, &request),
          "the request is built");
    JsonValue *parsed = json_parse(request.data);
    CHECK(parsed != NULL, "the request is still valid JSON");
    json_free(parsed);

    buffer_free(&request);
    conversation_free(&conversation);
    agent_config_free(&config);
}

/* The placeholder is what travels. There is no field in this program that
 * can hold a key, so a machine taken apart byte by byte yields a name. */
static void test_only_a_placeholder_is_configured(void) {
    AgentConfig config;
    agent_config_init(&config);
    CHECK(strchr(config.key_placeholder, '$') != NULL,
          "the configured credential is a placeholder");
    CHECK(strstr(config.key_placeholder, "sk-") == NULL,
          "no key is compiled in");
    agent_config_free(&config);
}

static void test_reply_with_a_tool_call(void) {
    AgentConfig config;
    agent_config_init(&config);
    const char *body =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,"
        "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":"
        "{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\","
        "\\\"cwd\\\":\\\"/workspace\\\"}\"}}]}}]}";

    LlmReply reply;
    char *error = NULL;
    CHECK(llm_parse_reply(body, strlen(body), &config, &reply, &error),
          "a tool call is read");
    CHECK(reply.has_tool_calls, "the reply is marked as calling a tool");
    CHECK_LONG_EQ(reply.tool_call_count, 1, "one call was made");
    CHECK_STR_EQ(reply.tool_calls[0].command, "ls -la", "the command survives");
    CHECK_STR_EQ(reply.tool_calls[0].cwd, "/workspace",
                 "the directory survives");
    CHECK_LONG_EQ(reply.tool_calls[0].timeout_ms, config.command_timeout_ms,
                  "a call without a timeout gets the configured one");
    CHECK(reply.raw_message != NULL,
          "the assistant message is kept so the next request replays it");
    llm_reply_free(&reply);
    free(error);
    agent_config_free(&config);
}

static void test_reply_with_a_final_answer(void) {
    AgentConfig config;
    agent_config_init(&config);
    const char *body =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\","
        "\"content\":\"There are 12 files.\"}}]}";

    LlmReply reply;
    char *error = NULL;
    CHECK(llm_parse_reply(body, strlen(body), &config, &reply, &error),
          "a plain answer is read");
    CHECK(!reply.has_tool_calls, "no tool was called");
    CHECK_STR_EQ(reply.content, "There are 12 files.", "the answer survives");
    llm_reply_free(&reply);
    free(error);
    agent_config_free(&config);
}

/* An unknown tool is the model's mistake to correct, so it comes back as a
 * decode error the loop can hand straight back rather than as a failure. */
static void test_an_unknown_tool_is_reported_not_fatal(void) {
    AgentConfig config;
    agent_config_init(&config);
    const char *body =
        "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"c\",\"function\":"
        "{\"name\":\"write_file\",\"arguments\":\"{}\"}}]}}]}";

    LlmReply reply;
    char *error = NULL;
    CHECK(llm_parse_reply(body, strlen(body), &config, &reply, &error),
          "the reply still parses");
    CHECK(reply.tool_calls[0].decode_error != NULL,
          "the unknown tool is reported");
    CHECK(reply.tool_calls[0].command == NULL, "nothing is run");
    llm_reply_free(&reply);
    free(error);
    agent_config_free(&config);
}

/* The host's proxy refuses in this exact shape, and the message names the
 * credential that is missing. The agent must be able to read it. */
static void test_a_proxy_refusal_is_surfaced(void) {
    AgentConfig config;
    agent_config_init(&config);
    const char *body =
        "{\"error\":{\"message\":\"No credential is configured for "
        "OPENROUTER_KEY.\",\"type\":\"dartemu_proxy\"}}";

    LlmReply reply;
    char *error = NULL;
    CHECK(!llm_parse_reply(body, strlen(body), &config, &reply, &error),
          "a refusal is not a reply");
    CHECK(error != NULL && strstr(error, "OPENROUTER_KEY") != NULL,
          "the reason names the credential the host needs");
    free(error);
    agent_config_free(&config);
}

static void test_a_torn_reply_fails_cleanly(void) {
    AgentConfig config;
    agent_config_init(&config);
    const char *body = "{\"choices\":[{\"message\":";
    LlmReply reply;
    char *error = NULL;
    CHECK(!llm_parse_reply(body, strlen(body), &config, &reply, &error),
          "half a reply is not accepted");
    CHECK(error != NULL, "the failure is explained");
    free(error);
    agent_config_free(&config);
}

static void test_the_system_prompt_states_the_real_limits(void) {
    AgentConfig config;
    agent_config_init(&config);
    config.max_output = 4096;
    config.command_timeout_ms = 30000;

    char *prompt = agent_system_prompt(&config);
    CHECK(prompt != NULL, "a prompt is built");
    CHECK(strstr(prompt, "4096") != NULL,
          "the output limit is the configured one");
    CHECK(strstr(prompt, "30 seconds") != NULL,
          "the timeout is the configured one");
    CHECK(strstr(prompt, "/llms.txt") != NULL,
          "the prompt points at the notes in the machine");
    CHECK(strstr(prompt, "placeholder") != NULL,
          "the agent is told it holds no credential");
    free(prompt);
    agent_config_free(&config);
}

static void test_a_result_reads_as_the_model_expects(void) {
    ShellResult result;
    shell_result_init(&result);
    result.exit_code = 2;
    result.timed_out = true;
    buffer_append_str(&result.output, "no such file");

    Buffer rendered;
    buffer_init(&rendered);
    CHECK(agent_format_result(&result, &rendered), "the result renders");
    CHECK(strstr(rendered.data, "exit_code: 2") != NULL,
          "the status is stated first");
    CHECK(strstr(rendered.data, "timed_out: true") != NULL,
          "a timeout is stated rather than implied");
    CHECK(strstr(rendered.data, "no such file") != NULL,
          "the output is included");
    buffer_free(&rendered);
    shell_result_free(&result);
}

int main(void) {
    test_request_carries_the_tool_and_the_messages();
    test_awkward_input_stays_inside_its_string();
    test_only_a_placeholder_is_configured();
    test_reply_with_a_tool_call();
    test_reply_with_a_final_answer();
    test_an_unknown_tool_is_reported_not_fatal();
    test_a_proxy_refusal_is_surfaced();
    test_a_torn_reply_fails_cleanly();
    test_the_system_prompt_states_the_real_limits();
    test_a_result_reads_as_the_model_expects();
    TEST_REPORT();
}
