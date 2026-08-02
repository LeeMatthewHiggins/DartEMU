#include "transcript.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { TIMESTAMP_LEN = 32 };

static void iso8601_now(char *out, size_t len) {
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &utc);
}

bool transcript_open(Transcript *transcript, const char *path) {
    memset(transcript, 0, sizeof(*transcript));
    if (path == NULL || path[0] == '\0') {
        return true; /* running without a transcript is allowed */
    }
    transcript->file = fopen(path, "a");
    if (transcript->file == NULL) {
        return false;
    }
    transcript->enabled = true;
    return true;
}

void transcript_close(Transcript *transcript) {
    if (transcript->file != NULL) {
        fclose(transcript->file);
    }
    memset(transcript, 0, sizeof(*transcript));
}

/* Writes one line and flushes, so a crash still leaves an auditable file. */
static void emit(Transcript *transcript, Buffer *line) {
    if (!transcript->enabled) {
        buffer_free(line);
        return;
    }
    buffer_append_str(line, "\n");
    fwrite(line->data, 1, line->len, transcript->file);
    fflush(transcript->file);
    buffer_free(line);
}

static void begin(Buffer *line, const char *type, long step) {
    char timestamp[TIMESTAMP_LEN];
    iso8601_now(timestamp, sizeof(timestamp));
    buffer_append_str(line, "{\"type\":");
    json_write_string(line, type, strlen(type));
    buffer_printf(line, ",\"step\":%ld,\"timestamp\":", step);
    json_write_string(line, timestamp, strlen(timestamp));
}

void transcript_write_start(Transcript *transcript, const char *task,
                            const char *model, const char *network_mode,
                            long max_steps, long max_seconds) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "task_start", 0);
    buffer_append_str(&line, ",\"task\":");
    json_write_string(&line, task, strlen(task));
    buffer_append_str(&line, ",\"model\":");
    json_write_string(&line, model, strlen(model));
    buffer_append_str(&line, ",\"network_mode\":");
    json_write_string(&line, network_mode, strlen(network_mode));
    buffer_printf(&line, ",\"max_steps\":%ld,\"max_seconds\":%ld}", max_steps,
                  max_seconds);
    emit(transcript, &line);
}

void transcript_write_tool_call(Transcript *transcript, long step,
                                const char *command, const char *cwd,
                                long timeout_ms) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "tool_call", step);
    buffer_append_str(&line, ",\"command\":");
    json_write_string(&line, command, strlen(command));
    if (cwd != NULL) {
        buffer_append_str(&line, ",\"cwd\":");
        json_write_string(&line, cwd, strlen(cwd));
    }
    buffer_printf(&line, ",\"timeout_ms\":%ld}", timeout_ms);
    emit(transcript, &line);
}

void transcript_write_tool_result(Transcript *transcript, long step,
                                  const ExecResult *result, long duration_ms) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "tool_result", step);
    buffer_printf(&line, ",\"exit_code\":%d", result->exit_code);
    buffer_append_str(&line, ",\"stdout\":");
    json_write_string(&line,
                      result->stdout_text.data != NULL
                          ? result->stdout_text.data
                          : "",
                      result->stdout_text.len);
    buffer_append_str(&line, ",\"stderr\":");
    json_write_string(&line,
                      result->stderr_text.data != NULL
                          ? result->stderr_text.data
                          : "",
                      result->stderr_text.len);
    buffer_printf(&line,
                  ",\"timed_out\":%s,\"stdout_truncated\":%s,"
                  "\"stderr_truncated\":%s,\"duration_ms\":%ld",
                  result->timed_out ? "true" : "false",
                  result->stdout_truncated ? "true" : "false",
                  result->stderr_truncated ? "true" : "false", duration_ms);
    if (result->transport_error) {
        buffer_append_str(&line, ",\"transport_error\":");
        const char *message = result->error_message != NULL
                                  ? result->error_message
                                  : "unknown transport error";
        json_write_string(&line, message, strlen(message));
    }
    buffer_append_str(&line, "}");
    emit(transcript, &line);
}

void transcript_write_assistant(Transcript *transcript, long step,
                                const char *content) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "assistant", step);
    buffer_append_str(&line, ",\"content\":");
    json_write_string(&line, content != NULL ? content : "",
                      content != NULL ? strlen(content) : 0);
    buffer_append_str(&line, "}");
    emit(transcript, &line);
}

void transcript_write_error(Transcript *transcript, long step,
                            const char *message) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "error", step);
    buffer_append_str(&line, ",\"message\":");
    json_write_string(&line, message, strlen(message));
    buffer_append_str(&line, "}");
    emit(transcript, &line);
}

void transcript_write_end(Transcript *transcript, const char *reason,
                          long steps_used, long elapsed_seconds,
                          const char *final_answer) {
    Buffer line;
    buffer_init(&line);
    begin(&line, "task_end", steps_used);
    buffer_append_str(&line, ",\"reason\":");
    json_write_string(&line, reason, strlen(reason));
    buffer_printf(&line, ",\"elapsed_seconds\":%ld", elapsed_seconds);
    buffer_append_str(&line, ",\"final_answer\":");
    json_write_string(&line, final_answer != NULL ? final_answer : "",
                      final_answer != NULL ? strlen(final_answer) : 0);
    buffer_append_str(&line, "}");
    emit(transcript, &line);
}
