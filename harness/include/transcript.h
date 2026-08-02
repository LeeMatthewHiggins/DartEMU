/* JSON Lines transcript: enough to audit the whole task afterwards. */
#ifndef HARNESS_TRANSCRIPT_H
#define HARNESS_TRANSCRIPT_H

#include <stdbool.h>
#include <stdio.h>

#include "protocol.h"

typedef struct {
    FILE *file;
    bool enabled;
} Transcript;

bool transcript_open(Transcript *transcript, const char *path);
void transcript_close(Transcript *transcript);

/* Records the task and the limits it ran under. Secrets are never written. */
void transcript_write_start(Transcript *transcript, const char *task,
                            const char *model, const char *network_mode,
                            long max_steps, long max_seconds);

void transcript_write_tool_call(Transcript *transcript, long step,
                                const char *command, const char *cwd,
                                long timeout_ms);

void transcript_write_tool_result(Transcript *transcript, long step,
                                  const ExecResult *result, long duration_ms);

void transcript_write_assistant(Transcript *transcript, long step,
                                const char *content);

void transcript_write_error(Transcript *transcript, long step,
                            const char *message);

/* Records why the run stopped and what it produced. */
void transcript_write_end(Transcript *transcript, const char *reason,
                          long steps_used, long elapsed_seconds,
                          const char *final_answer);

#endif /* HARNESS_TRANSCRIPT_H */
