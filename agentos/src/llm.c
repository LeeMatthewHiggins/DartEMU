#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentos.h"

enum {
    HTTP_OK = 200,
    CONVERSATION_MIN_CAP = 16,
    DEFAULT_PORT = 80,
    DEFAULT_MAX_STEPS = 24,
    DEFAULT_MAX_OUTPUT = 65536,
    DEFAULT_TIMEOUT_MS = 120000
};

/* The emulator's virtual gateway: the only address a guest can reach, and
 * where the host answers on the guest's behalf. */
static const char *const DEFAULT_GATEWAY = "10.0.2.2";
static const char *const DEFAULT_HOST = "llm.local";
static const char *const DEFAULT_PATH = "/v1/chat/completions";
static const char *const DEFAULT_MODEL = "openai/gpt-4o-mini";
static const char *const DEFAULT_KEY_PLACEHOLDER = "${OPENROUTER_KEY}";

/* The single tool. Its description tells the model the truth about the
 * machine: total freedom inside something disposable. */
static const char *const SHELL_TOOL_JSON =
    "{\"type\":\"function\",\"function\":{"
    "\"name\":\"shell\","
    "\"description\":\"Run any shell command on this machine. The machine is "
    "disposable and you have full root control of it. Destructive commands "
    "are permitted. Nothing you do reaches the host.\","
    "\"parameters\":{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\",\"description\":\"Shell command to "
    "execute.\"},"
    "\"cwd\":{\"type\":\"string\",\"description\":\"Optional working "
    "directory.\"},"
    "\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional command "
    "timeout in milliseconds.\"}"
    "},\"required\":[\"command\"]}}}";

/* ------------------------------------------------------------------ config */

void agent_config_init(AgentConfig *config) {
    memset(config, 0, sizeof(*config));
    config->gateway = strdup(DEFAULT_GATEWAY);
    config->host = strdup(DEFAULT_HOST);
    config->port = DEFAULT_PORT;
    config->path = strdup(DEFAULT_PATH);
    config->model = strdup(DEFAULT_MODEL);
    config->key_placeholder = strdup(DEFAULT_KEY_PLACEHOLDER);
    config->max_steps = DEFAULT_MAX_STEPS;
    config->max_output = DEFAULT_MAX_OUTPUT;
    config->command_timeout_ms = DEFAULT_TIMEOUT_MS;
}

void agent_config_free(AgentConfig *config) {
    free(config->gateway);
    free(config->host);
    free(config->path);
    free(config->model);
    free(config->key_placeholder);
    memset(config, 0, sizeof(*config));
}

/* ------------------------------------------------------------ conversation */

void conversation_init(Conversation *conversation) {
    memset(conversation, 0, sizeof(*conversation));
}

void conversation_free(Conversation *conversation) {
    for (size_t i = 0; i < conversation->count; i++) {
        free(conversation->messages[i]);
    }
    free(conversation->messages);
    memset(conversation, 0, sizeof(*conversation));
}

bool conversation_add_raw(Conversation *conversation, const char *json_object) {
    if (json_object == NULL) {
        return false;
    }
    if (conversation->count == conversation->capacity) {
        size_t cap = conversation->capacity == 0 ? CONVERSATION_MIN_CAP
                                                 : conversation->capacity * 2;
        char **grown = realloc(conversation->messages, cap * sizeof(char *));
        if (grown == NULL) {
            return false;
        }
        conversation->messages = grown;
        conversation->capacity = cap;
    }
    char *copy = strdup(json_object);
    if (copy == NULL) {
        return false;
    }
    conversation->messages[conversation->count++] = copy;
    return true;
}

bool conversation_add_text(Conversation *conversation, const char *role,
                           const char *text) {
    Buffer message;
    buffer_init(&message);
    bool ok = buffer_append_str(&message, "{\"role\":\"") &&
              buffer_append_str(&message, role) &&
              buffer_append_str(&message, "\",\"content\":") &&
              json_write_string(&message, text, strlen(text)) &&
              buffer_append_str(&message, "}");
    if (ok) {
        ok = conversation_add_raw(conversation, message.data);
    }
    buffer_free(&message);
    return ok;
}

bool conversation_add_tool_result(Conversation *conversation,
                                  const char *tool_call_id, const char *text,
                                  size_t text_len) {
    Buffer message;
    buffer_init(&message);
    bool ok =
        buffer_append_str(&message, "{\"role\":\"tool\",\"tool_call_id\":") &&
        json_write_string(&message, tool_call_id, strlen(tool_call_id)) &&
        buffer_append_str(&message, ",\"content\":") &&
        json_write_string(&message, text, text_len) &&
        buffer_append_str(&message, "}");
    if (ok) {
        ok = conversation_add_raw(conversation, message.data);
    }
    buffer_free(&message);
    return ok;
}

/* ------------------------------------------------------------------ replies */

void llm_reply_init(LlmReply *reply) { memset(reply, 0, sizeof(*reply)); }

void llm_reply_free(LlmReply *reply) {
    free(reply->content);
    free(reply->raw_message);
    for (size_t i = 0; i < reply->tool_call_count; i++) {
        free(reply->tool_calls[i].id);
        free(reply->tool_calls[i].command);
        free(reply->tool_calls[i].cwd);
        free(reply->tool_calls[i].decode_error);
    }
    free(reply->tool_calls);
    memset(reply, 0, sizeof(*reply));
}

/* Re-serialises the assistant message so the next request replays it exactly.
 * Only the fields the API needs are kept. */
static bool serialise_assistant(const JsonValue *message, Buffer *out) {
    if (!buffer_append_str(out, "{\"role\":\"assistant\"")) return false;

    const JsonValue *content = json_object_get(message, "content");
    if (content != NULL && content->type == JSON_STRING) {
        if (!buffer_append_str(out, ",\"content\":")) return false;
        if (!json_write_string(out, content->string, content->string_len)) {
            return false;
        }
    }

    const JsonValue *calls = json_object_get(message, "tool_calls");
    if (calls != NULL && calls->type == JSON_ARRAY) {
        if (!buffer_append_str(out, ",\"tool_calls\":[")) return false;
        size_t index = 0;
        for (const JsonValue *call = calls->first_child; call != NULL;
             call = call->next_sibling, index++) {
            const JsonValue *function = json_object_get(call, "function");
            const char *id = json_string_or(call, "id", "");
            const char *name = json_string_or(function, "name", "shell");
            const char *arguments = json_string_or(function, "arguments", "{}");
            if (index > 0 && !buffer_append_str(out, ",")) return false;
            if (!buffer_append_str(out, "{\"id\":")) return false;
            if (!json_write_string(out, id, strlen(id))) return false;
            if (!buffer_append_str(
                    out, ",\"type\":\"function\",\"function\":{\"name\":")) {
                return false;
            }
            if (!json_write_string(out, name, strlen(name))) return false;
            if (!buffer_append_str(out, ",\"arguments\":")) return false;
            if (!json_write_string(out, arguments, strlen(arguments))) {
                return false;
            }
            if (!buffer_append_str(out, "}}")) return false;
        }
        if (!buffer_append_str(out, "]")) return false;
    }
    return buffer_append_str(out, "}");
}

static void decode_tool_call(const JsonValue *call, const AgentConfig *config,
                             ToolCall *out) {
    memset(out, 0, sizeof(*out));
    out->id = strdup(json_string_or(call, "id", ""));
    out->timeout_ms = config->command_timeout_ms;

    const JsonValue *function = json_object_get(call, "function");
    const char *name = json_string_or(function, "name", "");
    if (strcmp(name, "shell") != 0) {
        char message[256];
        snprintf(message, sizeof(message),
                 "unknown tool '%s'; only 'shell' exists", name);
        out->decode_error = strdup(message);
        return;
    }

    const char *arguments = json_string_or(function, "arguments", NULL);
    if (arguments == NULL) {
        out->decode_error = strdup("tool call had no arguments");
        return;
    }
    JsonValue *parsed = json_parse(arguments);
    if (parsed == NULL || parsed->type != JSON_OBJECT) {
        json_free(parsed);
        out->decode_error = strdup("tool arguments were not a JSON object");
        return;
    }
    const JsonValue *command = json_object_get(parsed, "command");
    if (command == NULL || command->type != JSON_STRING) {
        json_free(parsed);
        out->decode_error = strdup("tool arguments had no 'command' string");
        return;
    }
    out->command = strndup(command->string, command->string_len);

    const JsonValue *cwd = json_object_get(parsed, "cwd");
    if (cwd != NULL && cwd->type == JSON_STRING && cwd->string_len > 0) {
        out->cwd = strndup(cwd->string, cwd->string_len);
    }
    double timeout = json_number_or(parsed, "timeout_ms", 0);
    if (timeout > 0) {
        out->timeout_ms = (long)timeout;
    }
    json_free(parsed);
}

bool llm_parse_reply(const char *body, size_t len, const AgentConfig *config,
                     LlmReply *reply, char **error) {
    llm_reply_init(reply);
    JsonValue *root = json_parse_len(body, len);
    if (root == NULL || root->type != JSON_OBJECT) {
        json_free(root);
        if (error != NULL) {
            *error = strdup("the reply was not JSON; the host proxy may have "
                            "refused the request");
        }
        return false;
    }

    /* A refusal from the host's proxy arrives in exactly this shape, so the
     * agent can read why it was stopped instead of seeing a dead socket. */
    const JsonValue *api_error = json_object_get(root, "error");
    if (api_error != NULL && api_error->type == JSON_OBJECT) {
        const char *message =
            json_string_or(api_error, "message", "the API reported an error");
        if (error != NULL) {
            *error = strdup(message);
        }
        json_free(root);
        return false;
    }

    const JsonValue *choices = json_object_get(root, "choices");
    const JsonValue *choice = json_array_at(choices, 0);
    const JsonValue *message = json_object_get(choice, "message");
    if (message == NULL || message->type != JSON_OBJECT) {
        json_free(root);
        if (error != NULL) {
            *error = strdup("the reply contained no message");
        }
        return false;
    }

    const JsonValue *content = json_object_get(message, "content");
    if (content != NULL && content->type == JSON_STRING) {
        reply->content = strndup(content->string, content->string_len);
    }

    Buffer raw;
    buffer_init(&raw);
    if (serialise_assistant(message, &raw)) {
        reply->raw_message = raw.data;
    } else {
        buffer_free(&raw);
    }

    const JsonValue *calls = json_object_get(message, "tool_calls");
    size_t count = json_array_size(calls);
    if (count > 0) {
        reply->tool_calls = calloc(count, sizeof(ToolCall));
        if (reply->tool_calls == NULL) {
            json_free(root);
            if (error != NULL) {
                *error = strdup("out of memory decoding tool calls");
            }
            return false;
        }
        size_t index = 0;
        for (const JsonValue *call = calls->first_child; call != NULL;
             call = call->next_sibling, index++) {
            decode_tool_call(call, config, &reply->tool_calls[index]);
        }
        reply->tool_call_count = count;
        reply->has_tool_calls = true;
    }

    json_free(root);
    return true;
}

bool llm_build_request(const AgentConfig *config,
                       const Conversation *conversation, Buffer *out) {
    if (!buffer_append_str(out, "{\"model\":")) return false;
    if (!json_write_string(out, config->model, strlen(config->model))) {
        return false;
    }
    if (!buffer_append_str(out, ",\"messages\":[")) return false;
    for (size_t i = 0; i < conversation->count; i++) {
        if (i > 0 && !buffer_append_str(out, ",")) return false;
        if (!buffer_append_str(out, conversation->messages[i])) return false;
    }
    if (!buffer_append_str(out, "],\"tools\":[")) return false;
    if (!buffer_append_str(out, SHELL_TOOL_JSON)) return false;
    return buffer_append_str(out, "],\"tool_choice\":\"auto\"}");
}

bool llm_complete(const AgentConfig *config, const Conversation *conversation,
                  LlmReply *reply, char **error) {
    Buffer request;
    buffer_init(&request);
    if (!llm_build_request(config, conversation, &request)) {
        buffer_free(&request);
        if (error != NULL) {
            *error = strdup("could not build the request");
        }
        return false;
    }

    /* The placeholder travels in place of a key. The host recognises the name
     * and substitutes the real value; nothing here ever holds one. */
    char authorization[256];
    snprintf(authorization, sizeof(authorization), "Bearer %s",
             config->key_placeholder);

    Buffer body;
    buffer_init(&body);
    int status = 0;
    bool sent =
        http_post(config->gateway, config->port, config->host, config->path,
                  authorization, request.data, &body, &status, error);
    buffer_free(&request);
    if (!sent) {
        buffer_free(&body);
        return false;
    }

    char *parse_error = NULL;
    bool ok = llm_parse_reply(body.data == NULL ? "" : body.data, body.len,
                              config, reply, &parse_error);
    buffer_free(&body);

    if (!ok) {
        if (error != NULL) {
            *error = parse_error != NULL ? parse_error
                                         : strdup("could not read the reply");
        } else {
            free(parse_error);
        }
        return false;
    }
    if (status != HTTP_OK) {
        llm_reply_free(reply);
        if (error != NULL) {
            char message[128];
            snprintf(message, sizeof(message), "the API returned HTTP %d",
                     status);
            *error = strdup(message);
        }
        return false;
    }
    free(parse_error);
    return true;
}
