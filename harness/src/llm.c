#include "llm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef HARNESS_NO_CURL
#include <curl/curl.h>
#endif

enum {
    MAX_ATTEMPTS = 4,
    RETRY_BASE_MS = 500,
    HTTP_OK = 200,
    HTTP_TOO_MANY = 429,
    HTTP_SERVER_ERROR = 500
};

/* The single tool. Its description tells the model the truth about the
 * environment: total freedom inside a disposable machine. */
static const char *const SHELL_TOOL_JSON =
    "{\"type\":\"function\",\"function\":{"
    "\"name\":\"shell\","
    "\"description\":\"Run any shell command inside the isolated guest "
    "machine. The machine is disposable and you have full root control of it. "
    "Destructive commands are permitted. Nothing you do affects the host.\","
    "\"parameters\":{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\",\"description\":\"Shell command to "
    "execute.\"},"
    "\"cwd\":{\"type\":\"string\",\"description\":\"Optional working directory "
    "inside the guest.\"},"
    "\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional command "
    "timeout in milliseconds.\"}"
    "},\"required\":[\"command\"]}}}";






/* -------------------------------------------------------------- responses */

void llm_response_init(LlmResponse *response) {
    memset(response, 0, sizeof(*response));
}

void llm_response_free(LlmResponse *response) {
    free(response->content);
    free(response->raw_message);
    for (size_t i = 0; i < response->tool_call_count; i++) {
        chat_tool_call_free(&response->tool_calls[i]);
    }
    free(response->tool_calls);
    memset(response, 0, sizeof(*response));
}



/* Parsing needs the default timeout, which lives in Config; tests that call
 * llm_parse_response directly get a zero-initialised one. */
static const Config *g_parse_config = NULL;

bool llm_parse_response(const char *body, size_t len, LlmResponse *response,
                        char **error) {
    llm_response_init(response);
    JsonValue *root = json_parse_len(body, len);
    if (root == NULL || root->type != JSON_OBJECT) {
        json_free(root);
        if (error != NULL) {
            *error = strdup("the API response was not a JSON object");
        }
        return false;
    }

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
            *error = strdup("the API response contained no message");
        }
        return false;
    }

    const JsonValue *content = json_object_get(message, "content");
    if (content != NULL && content->type == JSON_STRING) {
        response->content = strndup(content->string, content->string_len);
    }

    Buffer raw;
    buffer_init(&raw);
    if (chat_serialise_assistant(message, &raw)) {
        response->raw_message = raw.data;
    } else {
        buffer_free(&raw);
    }

    const JsonValue *calls = json_object_get(message, "tool_calls");
    size_t count = json_array_size(calls);
    if (count > 0) {
        response->tool_calls = calloc(count, sizeof(ToolCall));
        if (response->tool_calls == NULL) {
            json_free(root);
            if (error != NULL) {
                *error = strdup("out of memory decoding tool calls");
            }
            return false;
        }
        long timeout = g_parse_config != NULL
                           ? g_parse_config->default_command_timeout_ms
                           : 0;
        size_t index = 0;
        for (const JsonValue *call = calls->first_child; call != NULL;
             call = call->next_sibling, index++) {
            chat_decode_tool_call(call, timeout, &response->tool_calls[index]);
        }
        response->tool_call_count = count;
        response->has_tool_calls = true;
    }

    json_free(root);
    return true;
}

/* --------------------------------------------------------------- requests */

bool llm_build_request(const Config *config, const Conversation *conversation,
                       Buffer *out) {
    return chat_build_request(config->model, SHELL_TOOL_JSON, conversation,
                              out);
}

#ifndef HARNESS_NO_CURL

static size_t collect(char *data, size_t size, size_t count, void *user) {
    Buffer *buffer = user;
    return buffer_append(buffer, data, size * count) ? size * count : 0;
}

bool llm_global_init(void) {
    return curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
}

void llm_global_cleanup(void) { curl_global_cleanup(); }

static void sleep_ms(long ms) {
    struct timespec ts = {.tv_sec = ms / 1000,
                          .tv_nsec = (ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

bool llm_complete(const Config *config, const Conversation *conversation,
                  LlmResponse *response, char **error) {
    Buffer request;
    buffer_init(&request);
    if (!llm_build_request(config, conversation, &request)) {
        buffer_free(&request);
        if (error != NULL) *error = strdup("could not build the API request");
        return false;
    }

    char *last_error = NULL;
    bool ok = false;
    for (int attempt = 1; attempt <= MAX_ATTEMPTS && !ok; attempt++) {
        CURL *curl = curl_easy_init();
        if (curl == NULL) {
            free(last_error);
            last_error = strdup("could not initialise the HTTP client");
            break;
        }
        Buffer body;
        buffer_init(&body);

        struct curl_slist *headers = NULL;
        headers = curl_slist_append(headers, "Content-Type: application/json");
        char auth[1024];
        snprintf(auth, sizeof(auth), "Authorization: Bearer %s",
                 config->api_key);
        headers = curl_slist_append(headers, auth);

        curl_easy_setopt(curl, CURLOPT_URL, config->api_url);
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request.data);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)request.len);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);

        CURLcode code = curl_easy_perform(curl);
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);

        bool transient = false;
        if (code != CURLE_OK) {
            free(last_error);
            last_error = strdup(curl_easy_strerror(code));
            transient = true;
        } else if (status == HTTP_TOO_MANY || status >= HTTP_SERVER_ERROR) {
            char message[128];
            snprintf(message, sizeof(message), "the API returned HTTP %ld",
                     status);
            free(last_error);
            last_error = strdup(message);
            transient = true;
        } else if (status != HTTP_OK) {
            char *parse_error = NULL;
            /* A non-transient rejection: surface the API's own explanation. */
            if (!llm_parse_response(body.data == NULL ? "" : body.data,
                                    body.len, response, &parse_error)) {
                free(last_error);
                last_error = parse_error != NULL
                                 ? parse_error
                                 : strdup("the API rejected the request");
            } else {
                llm_response_free(response);
                char message[128];
                snprintf(message, sizeof(message), "the API returned HTTP %ld",
                         status);
                free(last_error);
                last_error = strdup(message);
            }
        } else {
            g_parse_config = config;
            char *parse_error = NULL;
            ok = llm_parse_response(body.data == NULL ? "" : body.data,
                                    body.len, response, &parse_error);
            g_parse_config = NULL;
            if (!ok) {
                free(last_error);
                last_error = parse_error != NULL
                                 ? parse_error
                                 : strdup("could not read the API response");
                /* Malformed JSON from a 200 is worth one more try. */
                transient = attempt < MAX_ATTEMPTS;
            }
        }
        buffer_free(&body);

        if (!ok && transient && attempt < MAX_ATTEMPTS) {
            if (config->verbose) {
                fprintf(stderr, "[llm] attempt %d failed: %s\n", attempt,
                        last_error != NULL ? last_error : "unknown");
            }
            sleep_ms(RETRY_BASE_MS << (attempt - 1));
            continue;
        }
        if (!ok) {
            break;
        }
    }

    buffer_free(&request);
    if (!ok && error != NULL) {
        *error = last_error != NULL ? last_error
                                    : strdup("the API call failed");
    } else {
        free(last_error);
    }
    return ok;
}

#else /* HARNESS_NO_CURL: tests link the parser without the network. */

bool llm_global_init(void) { return true; }
void llm_global_cleanup(void) {}

bool llm_complete(const Config *config, const Conversation *conversation,
                  LlmResponse *response, char **error) {
    (void)config;
    (void)conversation;
    (void)response;
    if (error != NULL) {
        *error = strdup("this build has no HTTP client");
    }
    return false;
}

#endif
