/* The chat-completions wire format: the message list, the assistant replay
 * and the single shell tool.
 *
 * Kept apart from llm.c because it is the protocol rather than the client —
 * what a request looks like, not how it is sent. Reply parsing lives with
 * the client, since it has to say which side refused a request and that is
 * a fact about the transport.
 */
#ifndef AGENTOS_CHAT_H
#define AGENTOS_CHAT_H

#include <stdbool.h>
#include <stddef.h>

#include "json.h"

/* Conversation, as complete JSON message objects. */
typedef struct {
    char **messages;
    size_t count;
    size_t capacity;
} Conversation;

void conversation_init(Conversation *conversation);
void conversation_free(Conversation *conversation);

/* Appends a message that is already a JSON object. */
bool conversation_add_raw(Conversation *conversation, const char *json_object);

/* Appends a message with the given role, escaping the text. */
bool conversation_add_text(Conversation *conversation, const char *role,
                           const char *text);

/* Appends the result of a tool call, escaping the text. Length is explicit
 * because command output may legitimately contain a NUL. */
bool conversation_add_tool_result(Conversation *conversation,
                                  const char *tool_call_id, const char *text,
                                  size_t text_len);

/* A single shell command the model asked for. */
typedef struct {
    char *id;
    char *command;
    char *cwd;
    long timeout_ms;
    /* Set when the call could not be understood. The caller hands this back
     * to the model as the tool result: a malformed call is a mistake to
     * correct, not a reason to end the session. */
    char *decode_error;
} ToolCall;

void chat_tool_call_free(ToolCall *call);

/* Reads one tool call, falling back to [default_timeout_ms] when the model
 * does not ask for a timeout. Never fails: what it cannot read it reports
 * through decode_error. */
void chat_decode_tool_call(const JsonValue *call, long default_timeout_ms,
                           ToolCall *out);

/* Re-serialises an assistant message so the next request replays it exactly.
 * Only the fields the API needs are kept. */
bool chat_serialise_assistant(const JsonValue *message, Buffer *out);

/* Builds a chat completions request body offering [tool_json] as the only
 * tool. */
bool chat_build_request(const char *model, const char *tool_json,
                        const Conversation *conversation, Buffer *out);

#endif /* AGENTOS_CHAT_H */
