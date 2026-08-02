#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentos.h"

enum {
    HTTP_OK = 200,
    DEFAULT_PORT = 80,
    DEFAULT_MAX_STEPS = 24,
    DEFAULT_MAX_OUTPUT = 65536,
    DEFAULT_TIMEOUT_MS = 120000
};

/* These three have to agree with the host on the other side of the wire, and
 * no compiler can check that: the host is Dart. The upstream name is what the
 * proxy routes on, and the placeholder is the name it substitutes a real key
 * for, both in example/lib/src/agentos/agentos_demo.dart. Change one, change
 * both, or the machine reaches a host that has never heard of it.
 *
 * The gateway is the emulator's own: the only address a guest can reach, and
 * where the host answers on its behalf. */
static const char *const DEFAULT_GATEWAY = "10.0.2.2";
static const char *const DEFAULT_HOST = "llm.local";
static const char *const DEFAULT_KEY_PLACEHOLDER = "${OPENROUTER_KEY}";

static const char *const DEFAULT_PATH = "/v1/chat/completions";
static const char *const DEFAULT_MODEL = "moonshotai/kimi-k3";

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






/* ------------------------------------------------------------------ replies */

void llm_reply_init(LlmReply *reply) { memset(reply, 0, sizeof(*reply)); }

void llm_reply_free(LlmReply *reply) {
    free(reply->content);
    free(reply->raw_message);
    for (size_t i = 0; i < reply->tool_call_count; i++) {
        chat_tool_call_free(&reply->tool_calls[i]);
    }
    free(reply->tool_calls);
    memset(reply, 0, sizeof(*reply));
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
     * agent can read why it was stopped instead of seeing a dead socket.
     *
     * Which side refused matters more than it looks. "no credential" from the
     * host and "no credential" from a provider read the same to whoever is
     * watching, and send them looking in the wrong place — so the proxy
     * marks its own, and anything unmarked is named as coming from beyond
     * it. */
    const JsonValue *api_error = json_object_get(root, "error");
    if (api_error != NULL && api_error->type == JSON_OBJECT) {
        const char *from = json_string_or(api_error, "type", "");
        bool from_host = strcmp(from, "dartemu_proxy") == 0;
        const char *message =
            json_string_or(api_error, "message", "the API reported an error");
        if (error != NULL) {
            Buffer explained;
            buffer_init(&explained);
            buffer_append_str(&explained, from_host
                                              ? "this machine's host refused "
                                                "the request: "
                                              : "the model API refused the "
                                                "request: ");
            buffer_append_str(&explained, message);
            *error = explained.data != NULL ? explained.data : strdup(message);
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
    if (chat_serialise_assistant(message, &raw)) {
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
            chat_decode_tool_call(call, config->command_timeout_ms,
                                  &reply->tool_calls[index]);
        }
        reply->tool_call_count = count;
        reply->has_tool_calls = true;
    }

    json_free(root);
    return true;
}

bool llm_build_request(const AgentConfig *config,
                       const Conversation *conversation, Buffer *out) {
    return chat_build_request(config->model, SHELL_TOOL_JSON, conversation,
                              out);
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
            /* The status says which layer answered even when the message
             * does not, and every layer here can produce a 401. */
            Buffer explained;
            buffer_init(&explained);
            if (status != HTTP_OK) {
                buffer_printf(&explained, "HTTP %d: ", status);
            }
            buffer_append_str(&explained,
                              parse_error != NULL
                                  ? parse_error
                                  : "could not read the reply");
            *error = explained.data;
        }
        free(parse_error);
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
