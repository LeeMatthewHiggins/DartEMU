/* Guest lifecycle and execution transport.
 *
 * Owns the disposable machine: makes the copy-on-write task disk, starts the
 * emulator, installs the execution daemon, ships commands to it and tears
 * everything down. Commands are passed through byte for byte — this layer
 * inspects nothing and forbids nothing.
 */
#ifndef HARNESS_GUEST_H
#define HARNESS_GUEST_H

#include <stdbool.h>
#include <sys/types.h>

#include "config.h"
#include "protocol.h"

typedef struct {
    const Config *config;
    pid_t emulator_pid;
    int to_guest;   /* write end of the guest console */
    int from_guest; /* read end of the guest console */
    Buffer pending; /* bytes read but not yet split into lines */
    long next_id;
    bool ready;
    char *task_disk;      /* the writable copy actually in use */
    char *vm_config_path; /* generated when a share is configured */
    char *last_error;
} Guest;

void guest_init(Guest *guest, const Config *config);

/* Creates the task disk, starts the emulator (or opens the serial device),
 * waits for a shell and installs the daemon. Returns false with
 * guest_last_error set when the machine never became usable. */
bool guest_start(Guest *guest);

/* Runs one command. Always fills result: a command that fails, times out or
 * loses the transport is reported, never treated as fatal by itself. */
void guest_exec(Guest *guest, const char *command, const char *cwd,
                long timeout_ms, ExecResult *result);

/* True while the guest can still accept commands. */
bool guest_is_alive(const Guest *guest);

const char *guest_last_error(const Guest *guest);

/* Copies the workspace out of the guest before shutdown. Best effort: a
 * failure here must not lose the transcript. */
bool guest_export_artifacts(Guest *guest, const char *destination);

/* Stops the emulator and removes the task disk unless it is being kept. */
void guest_shutdown(Guest *guest);

void guest_free(Guest *guest);

#endif /* HARNESS_GUEST_H */
