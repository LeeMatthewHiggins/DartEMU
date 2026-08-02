#include "chat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { CONVERSATION_MIN_CAP = 16 };

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

/* -------------------------------------------------------------- tool calls */

void chat_tool_call_free(ToolCall *call) {
    free(call->id);
    free(call->command);
    free(call->cwd);
    free(call->decode_error);
    memset(call, 0, sizeof(*call));
}

void chat_decode_tool_call(const JsonValue *call, long default_timeout_ms,
                           ToolCall *out) {
    memset(out, 0, sizeof(*out));
    out->id = strdup(json_string_or(call, "id", ""));
    out->timeout_ms = default_timeout_ms;

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

/* ---------------------------------------------------------------- requests */

bool chat_serialise_assistant(const JsonValue *message, Buffer *out) {
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

bool chat_build_request(const char *model, const char *tool_json,
                        const Conversation *conversation, Buffer *out) {
    if (!buffer_append_str(out, "{\"model\":")) return false;
    if (!json_write_string(out, model, strlen(model))) {
        return false;
    }
    if (!buffer_append_str(out, ",\"messages\":[")) return false;
    for (size_t i = 0; i < conversation->count; i++) {
        if (i > 0 && !buffer_append_str(out, ",")) return false;
        if (!buffer_append_str(out, conversation->messages[i])) return false;
    }
    if (!buffer_append_str(out, "],\"tools\":[")) return false;
    if (!buffer_append_str(out, tool_json)) return false;
    return buffer_append_str(out, "],\"tool_choice\":\"auto\"}");
}
