/* AgentOS: the agent that runs inside the machine.
 *
 * Driving a guest from outside needs an elaborate transport — newline
 * delimited JSON over a console, a shell daemon, base64 in both directions —
 * because the agent and the machine are separated by a console. This one is
 * inside, so running a command is fork and exec and none of that exists.
 * AgentSandbox in the Dart library is the outside arrangement, for images
 * that cannot be modified.
 *
 * It never holds a credential. Requests carry a placeholder naming the key
 * they need, and the host substitutes the real value on the way out, so a
 * machine that is entirely compromised yields a name.
 */
#ifndef AGENTOS_H
#define AGENTOS_H

#include <stdbool.h>
#include <stddef.h>

#include "chat.h"
#include "json.h"

/* ------------------------------------------------------------------ shell */

typedef struct {
    int exit_code;
    Buffer output; /* stdout and stderr, interleaved as the user would see */
    bool timed_out;
    bool truncated;
} ShellResult;

void shell_result_init(ShellResult *result);
void shell_result_free(ShellResult *result);

/* Runs a command with /bin/sh. Output is bounded as it is read, so a command
 * that prints without end cannot exhaust the machine's memory. */
void shell_run(const char *command, const char *cwd, long timeout_ms,
               size_t max_output, ShellResult *result);

/* -------------------------------------------------------------------- llm */

typedef struct {
    char *gateway;     /* where the host's proxy listens */
    char *host;        /* the named upstream, e.g. llm.local */
    int port;
    char *path;        /* e.g. /v1/chat/completions */
    char *model;
    char *key_placeholder; /* ${NAME}, never a key */
    long max_steps;
    size_t max_output;
    long command_timeout_ms;
} AgentConfig;

void agent_config_init(AgentConfig *config);
void agent_config_free(AgentConfig *config);

typedef struct {
    char *content;
    char *raw_message;
    ToolCall *tool_calls;
    size_t tool_call_count;
    bool has_tool_calls;
} LlmReply;

void llm_reply_init(LlmReply *reply);
void llm_reply_free(LlmReply *reply);

/* Builds the chat completions request body. Exposed for tests. */
bool llm_build_request(const AgentConfig *config,
                       const Conversation *conversation, Buffer *out);

/* Reads a chat completions response body. Exposed for tests. */
bool llm_parse_reply(const char *body, size_t len, const AgentConfig *config,
                     LlmReply *reply, char **error);

/* Performs one completion over a plain HTTP socket. */
bool llm_complete(const AgentConfig *config, const Conversation *conversation,
                  LlmReply *reply, char **error);

/* ------------------------------------------------------------------- http */

/* Sends a POST to the gateway, naming the upstream in the Host header, and
 * returns the response body, or false with error set.
 *
 * Plain HTTP by design: the host adds the TLS and the credential. */
bool http_post(const char *gateway, int port, const char *host,
               const char *path, const char *authorization, const char *body,
               Buffer *response, int *status_code, char **error);

/* Splits a raw HTTP response into its status and body. Exposed for tests. */
bool http_split_response(const char *raw, size_t len, int *status_code,
                         const char **body, size_t *body_len);

/* ------------------------------------------------------------------ agent */

/* Builds the system prompt from the configuration, so the model is told the
 * limits the machine actually has. Caller owns the result. */
char *agent_system_prompt(const AgentConfig *config);

/* Renders a shell result the way the model sees it. */
bool agent_format_result(const ShellResult *result, Buffer *out);

/* Runs the conversation loop on the console until end of input. */
int agent_main(const AgentConfig *config);

#endif /* AGENTOS_H */
