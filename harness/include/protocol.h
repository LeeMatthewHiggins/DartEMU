/* Guest execution protocol: newline-delimited JSON over the guest console.
 *
 * Request   {"id":17,"command":"make test","cwd":"/workspace","timeout_ms":120000}
 *            plus command_b64 / cwd_b64 carrying the same values
 * Response  {"id":17,"exit_code":1,"stdout":"...","stderr":"...","timed_out":false}
 *
 * The daemon that runs inside the guest is a POSIX shell script, which cannot
 * escape arbitrary bytes into a JSON string safely, so it may send `stdout_b64`
 * and `stderr_b64` instead. Both spellings decode to the same result here; the
 * plain form stays valid on the wire for any richer daemon.
 */
#ifndef HARNESS_PROTOCOL_H
#define HARNESS_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>

#include "json.h"

typedef struct {
    long id;
    const char *command; /* passed through verbatim, never inspected */
    const char *cwd;     /* NULL to leave the daemon's working directory */
    long timeout_ms;     /* <= 0 to let the daemon apply its default */
} ExecRequest;

typedef struct {
    long id;
    int exit_code;
    Buffer stdout_text;
    Buffer stderr_text;
    bool timed_out;
    bool stdout_truncated;
    bool stderr_truncated;
    /* Set when the harness itself failed rather than the command: a malformed
     * frame, a lost transport, or a response that never arrived. */
    bool transport_error;
    char *error_message;
} ExecResult;

void exec_result_init(ExecResult *result);
void exec_result_free(ExecResult *result);

/* Sets the transport error state, replacing any previous message. */
void exec_result_fail(ExecResult *result, const char *message);

/* Serialises a request as one NDJSON line, trailing newline included. */
bool protocol_encode_request(Buffer *out, const ExecRequest *request);

/* Parses one response line. Returns false when the line is not a usable
 * response, filling result with a transport error describing why. Output
 * fields are capped at max_output_bytes and marked when truncated. */
bool protocol_decode_response(const char *line, size_t len,
                              size_t max_output_bytes, ExecResult *result);

/* Appends the marker the harness shows the model when output was cut. */
bool protocol_append_truncation_note(Buffer *out, size_t max_output_bytes);

/* Decodes base64, tolerating embedded whitespace. Returns false on invalid
 * input, which the caller should treat as a malformed frame. */
bool protocol_base64_decode(const char *text, size_t len, Buffer *out);

/* Encodes bytes as base64 with no line breaks. */
bool protocol_base64_encode(const char *bytes, size_t len, Buffer *out);

/* The guest-side daemon, a POSIX shell script. Installed over the console at
 * session start so the shipped guest images need no rebuild. */
const char *protocol_guest_daemon_script(void);

#endif /* HARNESS_PROTOCOL_H */
