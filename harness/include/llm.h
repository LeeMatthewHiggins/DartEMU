/* OpenAI-compatible chat completions client with native tool calling. */
#ifndef HARNESS_LLM_H
#define HARNESS_LLM_H

#include <stdbool.h>
#include <stddef.h>

#include "chat.h"
#include "config.h"
#include "json.h"

typedef struct {
    char *content; /* assistant text, may be NULL */
    ToolCall *tool_calls;
    size_t tool_call_count;
    bool has_tool_calls;
    /* The raw assistant message, replayed into the next request so the API
     * sees exactly what it produced. */
    char *raw_message;
} LlmResponse;

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
