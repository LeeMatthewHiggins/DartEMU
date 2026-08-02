/* OpenAI-compatible chat completions client with native tool calling. */
#ifndef HARNESS_LLM_H
#define HARNESS_LLM_H

#include <stdbool.h>
#include <stddef.h>

#include "config.h"
#include "json.h"

typedef struct {
    char *id;      /* tool_call id the result must be addressed to */
    char *command; /* passed to the guest verbatim */
    char *cwd;     /* NULL when the model did not ask for one */
    long timeout_ms;
    /* Set when the arguments could not be understood; the loop reports this
     * back to the model as a tool result rather than aborting. */
    char *decode_error;
} ToolCall;

typedef struct {
    char *content; /* assistant text, may be NULL */
    ToolCall *tool_calls;
    size_t tool_call_count;
    bool has_tool_calls;
    /* The raw assistant message, replayed into the next request so the API
     * sees exactly what it produced. */
    char *raw_message;
} LlmResponse;

/* Conversation state. Messages are stored as complete JSON objects. */
typedef struct {
    char **messages;
    size_t count;
    size_t capacity;
} Conversation;

void conversation_init(Conversation *conversation);
void conversation_free(Conversation *conversation);
bool conversation_add_raw(Conversation *conversation, const char *json_object);
bool conversation_add_text(Conversation *conversation, const char *role,
                           const char *text);
bool conversation_add_tool_result(Conversation *conversation,
                                  const char *tool_call_id, const char *text,
                                  size_t text_len);

void llm_response_init(LlmResponse *response);
void llm_response_free(LlmResponse *response);

/* Global curl setup and teardown. */
bool llm_global_init(void);
void llm_global_cleanup(void);

/* One chat completion. Retries only transient failures — network errors and
 * 429/5xx — never a well-formed rejection. Returns false with error filled
 * when the call could not be completed. */
bool llm_complete(const Config *config, const Conversation *conversation,
                  LlmResponse *response, char **error);

/* Exposed for tests: parses a chat completions response body. */
bool llm_parse_response(const char *body, size_t len, LlmResponse *response,
                        char **error);

/* Exposed for tests: builds the request body. */
bool llm_build_request(const Config *config, const Conversation *conversation,
                       Buffer *out);

#endif /* HARNESS_LLM_H */
