#include "protocol.h"

#include <stdlib.h>
#include <string.h>

void exec_result_init(ExecResult *result) {
    memset(result, 0, sizeof(*result));
    buffer_init(&result->stdout_text);
    buffer_init(&result->stderr_text);
    result->exit_code = -1;
}

void exec_result_free(ExecResult *result) {
    buffer_free(&result->stdout_text);
    buffer_free(&result->stderr_text);
    free(result->error_message);
    result->error_message = NULL;
}

void exec_result_fail(ExecResult *result, const char *message) {
    result->transport_error = true;
    free(result->error_message);
    result->error_message = message != NULL ? strdup(message) : NULL;
}

bool protocol_encode_request(Buffer *out, const ExecRequest *request) {
    if (request->command == NULL) {
        return false;
    }
    if (!buffer_append_str(out, "{\"id\":")) return false;
    if (!json_write_number(out, (double)request->id)) return false;
    if (!buffer_append_str(out, ",\"command\":")) return false;
    if (!json_write_string(out, request->command, strlen(request->command))) {
        return false;
    }
    /* The guest daemon is a POSIX shell script and cannot unescape a JSON
     * string reliably, so the same values also travel base64-encoded. The
     * documented plain fields stay on the wire for any richer daemon. */
    if (!buffer_append_str(out, ",\"command_b64\":\"")) return false;
    if (!protocol_base64_encode(request->command, strlen(request->command),
                                out)) {
        return false;
    }
    if (!buffer_append_str(out, "\"")) return false;

    if (request->cwd != NULL && request->cwd[0] != '\0') {
        if (!buffer_append_str(out, ",\"cwd\":")) return false;
        if (!json_write_string(out, request->cwd, strlen(request->cwd))) {
            return false;
        }
        if (!buffer_append_str(out, ",\"cwd_b64\":\"")) return false;
        if (!protocol_base64_encode(request->cwd, strlen(request->cwd), out)) {
            return false;
        }
        if (!buffer_append_str(out, "\"")) return false;
    }
    if (request->timeout_ms > 0) {
        if (!buffer_append_str(out, ",\"timeout_ms\":")) return false;
        if (!json_write_number(out, (double)request->timeout_ms)) return false;
    }
    return buffer_append_str(out, "}\n");
}

bool protocol_append_truncation_note(Buffer *out, size_t max_output_bytes) {
    return buffer_printf(out,
                         "\n[output truncated by harness at %zu bytes]\n",
                         max_output_bytes);
}

/* ---------------------------------------------------------------- base64 */

static int base64_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static const char BASE64_ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

bool protocol_base64_encode(const char *bytes, size_t len, Buffer *out) {
    const unsigned char *in = (const unsigned char *)bytes;
    for (size_t i = 0; i < len; i += 3) {
        unsigned block = (unsigned)in[i] << 16;
        size_t have = 1;
        if (i + 1 < len) {
            block |= (unsigned)in[i + 1] << 8;
            have = 2;
        }
        if (i + 2 < len) {
            block |= (unsigned)in[i + 2];
            have = 3;
        }
        char quad[4];
        quad[0] = BASE64_ALPHABET[(block >> 18) & 0x3Fu];
        quad[1] = BASE64_ALPHABET[(block >> 12) & 0x3Fu];
        quad[2] = have > 1 ? BASE64_ALPHABET[(block >> 6) & 0x3Fu] : '=';
        quad[3] = have > 2 ? BASE64_ALPHABET[block & 0x3Fu] : '=';
        if (!buffer_append(out, quad, 4)) {
            return false;
        }
    }
    return len == 0 ? buffer_append(out, "", 0) : true;
}

bool protocol_base64_decode(const char *text, size_t len, Buffer *out) {
    unsigned accumulator = 0;
    int bits = 0;
    size_t padding = 0;
    for (size_t i = 0; i < len; i++) {
        char c = text[i];
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') {
            continue;
        }
        if (c == '=') {
            padding++;
            continue;
        }
        if (padding > 0) {
            return false; /* data after padding */
        }
        int value = base64_value(c);
        if (value < 0) {
            return false;
        }
        accumulator = (accumulator << 6) | (unsigned)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            char byte = (char)((accumulator >> bits) & 0xFFu);
            if (!buffer_append(out, &byte, 1)) {
                return false;
            }
        }
    }
    return padding <= 2;
}

/* -------------------------------------------------------------- responses */

/* Copies at most max_output_bytes into out, reporting whether it had to cut. */
static bool copy_capped(Buffer *out, const char *text, size_t len,
                        size_t max_output_bytes, bool *truncated) {
    size_t keep = len;
    *truncated = false;
    if (max_output_bytes > 0 && len > max_output_bytes) {
        keep = max_output_bytes;
        *truncated = true;
    }
    if (!buffer_append(out, text, keep)) {
        return false;
    }
    if (*truncated) {
        return protocol_append_truncation_note(out, max_output_bytes);
    }
    return true;
}

/* Reads one output stream, accepting either the plain or the base64 field. */
static bool read_stream(const JsonValue *root, const char *plain_key,
                        const char *b64_key, size_t max_output_bytes,
                        Buffer *out, bool *truncated, const char **error) {
    const JsonValue *b64 = json_object_get(root, b64_key);
    if (b64 != NULL) {
        if (b64->type != JSON_STRING) {
            *error = "base64 output field is not a string";
            return false;
        }
        Buffer decoded;
        buffer_init(&decoded);
        if (!protocol_base64_decode(b64->string, b64->string_len, &decoded)) {
            buffer_free(&decoded);
            *error = "base64 output field could not be decoded";
            return false;
        }
        bool ok = copy_capped(out, decoded.data == NULL ? "" : decoded.data,
                              decoded.len, max_output_bytes, truncated);
        buffer_free(&decoded);
        return ok;
    }

    const JsonValue *plain = json_object_get(root, plain_key);
    if (plain == NULL) {
        return true; /* absent stream is simply empty */
    }
    if (plain->type != JSON_STRING) {
        *error = "output field is not a string";
        return false;
    }
    return copy_capped(out, plain->string, plain->string_len, max_output_bytes,
                       truncated);
}

bool protocol_decode_response(const char *line, size_t len,
                              size_t max_output_bytes, ExecResult *result) {
    JsonValue *root = json_parse_len(line, len);
    if (root == NULL || root->type != JSON_OBJECT) {
        json_free(root);
        exec_result_fail(result, "guest sent a line that is not a JSON object");
        return false;
    }

    const JsonValue *id = json_object_get(root, "id");
    if (id == NULL || id->type != JSON_NUMBER) {
        json_free(root);
        exec_result_fail(result, "guest response is missing a numeric id");
        return false;
    }
    result->id = (long)id->number;
    result->exit_code = (int)json_number_or(root, "exit_code", -1);
    result->timed_out = json_bool_or(root, "timed_out", false);

    const char *error = NULL;
    if (!read_stream(root, "stdout", "stdout_b64", max_output_bytes,
                     &result->stdout_text, &result->stdout_truncated, &error) ||
        !read_stream(root, "stderr", "stderr_b64", max_output_bytes,
                     &result->stderr_text, &result->stderr_truncated, &error)) {
        json_free(root);
        exec_result_fail(result, error != NULL ? error
                                               : "guest response was unusable");
        return false;
    }

    json_free(root);
    return true;
}

/* ----------------------------------------------------------- guest daemon */

/* Reads one request per line and answers with one response per line.
 *
 * Output is base64-encoded because escaping arbitrary command output into a
 * JSON string from a POSIX shell is not something to attempt. Fields are
 * pulled out with sed rather than a JSON parser, which the harness compensates
 * for by sending requests whose shape it controls exactly.
 */
static const char *const GUEST_DAEMON =
    "cat > /tmp/.harnessd <<'HARNESS_EOF'\n"
    "#!/bin/sh\n"
    "# dartemu agent harness guest daemon\n"
    "# Values arrive base64-encoded, so no JSON string parsing happens here:\n"
    "# a greedy sed would otherwise swallow every field after the first quote\n"
    "# in a command like: echo \"hi\"\n"
    "b64field() { printf '%s' \"$1\" | sed -n \"s/.*\\\"$2\\\"[ ]*:[ ]*\\\"\\\\([A-Za-z0-9+/=]*\\\\)\\\".*/\\\\1/p\"; }\n"
    "num() { printf '%s' \"$1\" | sed -n \"s/.*\\\"$2\\\"[ ]*:[ ]*\\\\([0-9-]*\\\\).*/\\\\1/p\"; }\n"
    "dec() { printf '%s' \"$1\" | base64 -d 2>/dev/null; }\n"
    "enc() { base64 2>/dev/null | tr -d '\\n'; }\n"
    "cd /workspace 2>/dev/null || cd /\n"
    "printf 'HARNESS_READY\\n'\n"
    "while IFS= read -r line; do\n"
    "  case \"$line\" in *'\"id\"'*) ;; *) continue ;; esac\n"
    "  id=$(num \"$line\" id)\n"
    "  [ -z \"$id\" ] && continue\n"
    "  cmdfile=/tmp/.h_cmd.$id\n"
    "  dec \"$(b64field \"$line\" command_b64)\" > \"$cmdfile\"\n"
    "  dir=$(dec \"$(b64field \"$line\" cwd_b64)\")\n"
    "  tmo=$(num \"$line\" timeout_ms)\n"
    "  out=/tmp/.h_out.$id; err=/tmp/.h_err.$id\n"
    "  ( [ -n \"$dir\" ] && cd \"$dir\" 2>/dev/null; sh \"$cmdfile\" ) >\"$out\" 2>\"$err\" &\n"
    "  pid=$!\n"
    "  timedout=false\n"
    "  if [ -n \"$tmo\" ] && [ \"$tmo\" -gt 0 ] 2>/dev/null; then\n"
    "    secs=$((tmo / 1000)); [ \"$secs\" -lt 1 ] && secs=1\n"
    "    # Mark before killing: wait returns the instant the child dies and\n"
    "    # the watchdog is killed next, so marking after loses the race.\n"
    "    ( sleep \"$secs\"; : > /tmp/.h_to.$id; kill -9 \"$pid\" 2>/dev/null ) &\n"
    "    watch=$!\n"
    "    wait \"$pid\"; rc=$?\n"
    "    kill -9 \"$watch\" 2>/dev/null\n"
    "    if [ -f /tmp/.h_to.$id ]; then timedout=true; rm -f /tmp/.h_to.$id; fi\n"
    "  else\n"
    "    wait \"$pid\"; rc=$?\n"
    "  fi\n"
    "  printf '{\"id\":%s,\"exit_code\":%s,\"timed_out\":%s,\"stdout_b64\":\"%s\",\"stderr_b64\":\"%s\"}\\n' \\\n"
    "    \"$id\" \"$rc\" \"$timedout\" \"$(enc <\"$out\")\" \"$(enc <\"$err\")\"\n"
    "  rm -f \"$out\" \"$err\" \"$cmdfile\"\n"
    "done\n"
    "HARNESS_EOF\n"
    "sh /tmp/.harnessd\n";

const char *protocol_guest_daemon_script(void) { return GUEST_DAEMON; }
