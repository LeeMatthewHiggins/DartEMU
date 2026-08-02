#include "guest.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum {
    READ_CHUNK = 4096,
    BOOT_POLL_MS = 200,
    /* Emulated boots are slow; the daemon banner is the real signal. */
    DAEMON_READY_TIMEOUT_MS = 300000,
    SHUTDOWN_GRACE_MS = 2000,
    /* Headroom over the command's own timeout before the transport is
     * declared lost, so a guest-side kill still reports as a timeout. */
    TRANSPORT_GRACE_MS = 15000
};

static const char *const READY_MARKER = "HARNESS_READY";

static void set_error(Guest *guest, const char *message) {
    free(guest->last_error);
    guest->last_error = message != NULL ? strdup(message) : NULL;
}

void guest_init(Guest *guest, const Config *config) {
    memset(guest, 0, sizeof(*guest));
    guest->config = config;
    guest->to_guest = -1;
    guest->from_guest = -1;
    guest->next_id = 1;
    buffer_init(&guest->pending);
}

const char *guest_last_error(const Guest *guest) {
    return guest->last_error != NULL ? guest->last_error : "unknown error";
}

bool guest_is_alive(const Guest *guest) {
    return guest->ready && guest->from_guest >= 0;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

/* --------------------------------------------------------------- task disk */

/* Copies the base image so the agent's writes never touch it. DartEMU writes
 * a file-backed drive through to the host file, so the copy is what makes the
 * guest disposable. */
static bool make_task_disk(Guest *guest) {
    const Config *config = guest->config;
    if (config->base_disk_image == NULL) {
        return true;
    }

    char *path;
    if (config->task_disk_path != NULL) {
        path = strdup(config->task_disk_path);
    } else {
        char generated[512];
        snprintf(generated, sizeof(generated), "%s/harness-task-%d.img",
                 getenv("TMPDIR") != NULL ? getenv("TMPDIR") : "/tmp",
                 (int)getpid());
        path = strdup(generated);
    }
    if (path == NULL) {
        set_error(guest, "out of memory building the task disk path");
        return false;
    }

    FILE *src = fopen(config->base_disk_image, "rb");
    if (src == NULL) {
        set_error(guest, "cannot open the base disk image");
        free(path);
        return false;
    }
    FILE *dst = fopen(path, "wb");
    if (dst == NULL) {
        set_error(guest, "cannot create the task disk");
        fclose(src);
        free(path);
        return false;
    }
    char chunk[65536];
    size_t got;
    bool ok = true;
    while ((got = fread(chunk, 1, sizeof(chunk), src)) > 0) {
        if (fwrite(chunk, 1, got, dst) != got) {
            ok = false;
            break;
        }
    }
    fclose(src);
    if (fclose(dst) != 0) {
        ok = false;
    }
    if (!ok) {
        set_error(guest, "failed while copying the base disk image");
        unlink(path);
        free(path);
        return false;
    }
    guest->task_disk = path;
    return true;
}

/* ---------------------------------------------------------------- process */

static bool spawn_emulator(Guest *guest) {
    const Config *config = guest->config;
    int to_child[2];
    int from_child[2];
    if (pipe(to_child) != 0 || pipe(from_child) != 0) {
        set_error(guest, "cannot create pipes for the emulator");
        return false;
    }

    Buffer command;
    buffer_init(&command);
    buffer_append_str(&command, config->emulator_command);
    if (config->machine != NULL) {
        buffer_printf(&command, " --machine %s", config->machine);
    }
    buffer_printf(&command, " --memory %ld", config->memory_mb);
    if (config->bios_path != NULL) {
        buffer_printf(&command, " --bios '%s'", config->bios_path);
    }
    if (config->kernel_path != NULL) {
        buffer_printf(&command, " --kernel '%s'", config->kernel_path);
    }
    if (guest->task_disk != NULL) {
        buffer_printf(&command, " --drive '%s'", guest->task_disk);
    }

    pid_t pid = fork();
    if (pid < 0) {
        set_error(guest, "cannot fork the emulator");
        buffer_free(&command);
        return false;
    }
    if (pid == 0) {
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);
        dup2(from_child[1], STDERR_FILENO);
        close(to_child[0]);
        close(to_child[1]);
        close(from_child[0]);
        close(from_child[1]);
        /* Own process group, so shutdown can take the whole tree down. */
        setpgid(0, 0);
        execl("/bin/sh", "sh", "-c", command.data, (char *)NULL);
        _exit(127);
    }

    close(to_child[0]);
    close(from_child[1]);
    guest->emulator_pid = pid;
    guest->to_guest = to_child[1];
    guest->from_guest = from_child[0];
    buffer_free(&command);
    return true;
}

static bool open_serial(Guest *guest) {
    int fd = open(guest->config->guest_serial_device, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        set_error(guest, "cannot open the guest serial device");
        return false;
    }
    guest->to_guest = fd;
    guest->from_guest = fd;
    return true;
}

/* ------------------------------------------------------------------- I/O */

static bool write_all(Guest *guest, const char *bytes, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t wrote = write(guest->to_guest, bytes + sent, len - sent);
        if (wrote < 0) {
            if (errno == EINTR) {
                continue;
            }
            set_error(guest, "lost the guest transport while writing");
            guest->ready = false;
            return false;
        }
        sent += (size_t)wrote;
    }
    return true;
}

/* Reads whatever is available, appending to the pending buffer. Returns false
 * when the transport has closed. */
static bool pump(Guest *guest, int timeout_ms, bool *had_data) {
    *had_data = false;
    struct pollfd pfd = {.fd = guest->from_guest, .events = POLLIN};
    int ready = poll(&pfd, 1, timeout_ms);
    if (ready < 0) {
        if (errno == EINTR) {
            return true;
        }
        set_error(guest, "poll failed on the guest transport");
        return false;
    }
    if (ready == 0) {
        return true;
    }
    char chunk[READ_CHUNK];
    ssize_t got = read(guest->from_guest, chunk, sizeof(chunk));
    if (got < 0) {
        if (errno == EINTR || errno == EAGAIN) {
            return true;
        }
        set_error(guest, "read failed on the guest transport");
        return false;
    }
    if (got == 0) {
        set_error(guest, "the guest closed its console");
        return false;
    }
    *had_data = true;
    return buffer_append(&guest->pending, chunk, (size_t)got);
}

/* Removes and returns the first complete line, or NULL when none is buffered.
 * The caller owns the result. */
static char *take_line(Guest *guest, size_t *out_len) {
    if (guest->pending.data == NULL) {
        return NULL;
    }
    char *newline = memchr(guest->pending.data, '\n', guest->pending.len);
    if (newline == NULL) {
        return NULL;
    }
    size_t line_len = (size_t)(newline - guest->pending.data);
    char *line = malloc(line_len + 1);
    if (line == NULL) {
        return NULL;
    }
    memcpy(line, guest->pending.data, line_len);
    line[line_len] = '\0';

    size_t remaining = guest->pending.len - line_len - 1;
    memmove(guest->pending.data, newline + 1, remaining);
    guest->pending.len = remaining;
    guest->pending.data[remaining] = '\0';

    /* Strip a trailing carriage return from the guest's line discipline. */
    if (line_len > 0 && line[line_len - 1] == '\r') {
        line[line_len - 1] = '\0';
        line_len--;
    }
    *out_len = line_len;
    return line;
}

/* ------------------------------------------------------------------ start */

static bool wait_for_ready(Guest *guest, long timeout_ms) {
    long deadline = now_ms() + timeout_ms;
    for (;;) {
        size_t line_len;
        char *line;
        while ((line = take_line(guest, &line_len)) != NULL) {
            bool is_ready = strstr(line, READY_MARKER) != NULL;
            if (guest->config->verbose) {
                fprintf(stderr, "[guest] %s\n", line);
            }
            free(line);
            if (is_ready) {
                return true;
            }
        }
        long remaining = deadline - now_ms();
        if (remaining <= 0) {
            set_error(guest,
                      "the guest execution daemon never reported ready");
            return false;
        }
        bool had_data;
        int slice = remaining < BOOT_POLL_MS ? (int)remaining : BOOT_POLL_MS;
        if (!pump(guest, slice, &had_data)) {
            return false;
        }
    }
}

bool guest_start(Guest *guest) {
    if (!make_task_disk(guest)) {
        return false;
    }
    if (guest->config->guest_serial_device != NULL) {
        if (!open_serial(guest)) {
            return false;
        }
    } else if (!spawn_emulator(guest)) {
        return false;
    }

    /* Interrupt whatever the console is doing, then install the daemon. Its
     * banner is what tells us the guest is genuinely executing commands. */
    if (!write_all(guest, "\n", 1)) {
        return false;
    }
    if (!write_all(guest, protocol_guest_daemon_script(),
                   strlen(protocol_guest_daemon_script()))) {
        return false;
    }
    if (!wait_for_ready(guest, DAEMON_READY_TIMEOUT_MS)) {
        return false;
    }
    guest->ready = true;
    return true;
}

/* ------------------------------------------------------------------- exec */

void guest_exec(Guest *guest, const char *command, const char *cwd,
                long timeout_ms, ExecResult *result) {
    exec_result_init(result);
    if (!guest_is_alive(guest)) {
        exec_result_fail(result, "the guest is no longer available");
        return;
    }

    long id = guest->next_id++;
    long effective_timeout = timeout_ms > 0
                                 ? timeout_ms
                                 : guest->config->default_command_timeout_ms;

    ExecRequest request = {.id = id,
                           .command = command,
                           .cwd = cwd,
                           .timeout_ms = effective_timeout};
    Buffer line;
    buffer_init(&line);
    if (!protocol_encode_request(&line, &request)) {
        buffer_free(&line);
        exec_result_fail(result, "could not encode the command");
        return;
    }
    bool sent = write_all(guest, line.data, line.len);
    buffer_free(&line);
    if (!sent) {
        exec_result_fail(result, guest_last_error(guest));
        return;
    }

    long deadline = now_ms() + effective_timeout + TRANSPORT_GRACE_MS;
    for (;;) {
        size_t response_len;
        char *response;
        while ((response = take_line(guest, &response_len)) != NULL) {
            /* The console also carries shell echo and kernel chatter, so
             * anything that is not our response is skipped rather than
             * treated as a protocol violation. */
            if (response_len == 0 || response[0] != '{') {
                free(response);
                continue;
            }
            ExecResult decoded;
            exec_result_init(&decoded);
            bool ok = protocol_decode_response(
                response, response_len, guest->config->max_command_output_bytes,
                &decoded);
            free(response);
            if (!ok) {
                exec_result_free(&decoded);
                continue; /* not a response we can use; keep looking */
            }
            if (decoded.id != id) {
                exec_result_free(&decoded);
                continue; /* a stale response from an earlier command */
            }
            exec_result_free(result);
            *result = decoded;
            return;
        }

        long remaining = deadline - now_ms();
        if (remaining <= 0) {
            exec_result_fail(result,
                             "the guest did not answer before the transport "
                             "deadline");
            result->timed_out = true;
            guest->ready = false;
            return;
        }
        bool had_data;
        int slice = remaining < BOOT_POLL_MS ? (int)remaining : BOOT_POLL_MS;
        if (!pump(guest, slice, &had_data)) {
            exec_result_fail(result, guest_last_error(guest));
            guest->ready = false;
            return;
        }
    }
}

/* -------------------------------------------------------------- artifacts */

bool guest_export_artifacts(Guest *guest, const char *destination) {
    if (destination == NULL || !guest_is_alive(guest)) {
        return false;
    }
    /* Ask the guest to tar the workspace to stdout in base64, which needs no
     * extra transport and works with the tools already in the image. */
    ExecResult result;
    guest_exec(guest,
               "tar cf - -C /workspace . 2>/dev/null | base64 2>/dev/null",
               NULL, guest->config->default_command_timeout_ms, &result);

    bool ok = false;
    if (!result.transport_error && result.stdout_text.len > 0 &&
        !result.stdout_truncated) {
        Buffer decoded;
        buffer_init(&decoded);
        if (protocol_base64_decode(result.stdout_text.data,
                                   result.stdout_text.len, &decoded)) {
            FILE *out = fopen(destination, "wb");
            if (out != NULL) {
                ok = fwrite(decoded.data, 1, decoded.len, out) == decoded.len;
                if (fclose(out) != 0) {
                    ok = false;
                }
            }
        }
        buffer_free(&decoded);
    } else if (result.stdout_truncated) {
        set_error(guest,
                  "the workspace archive exceeded the output cap; raise "
                  "--max-output to export it");
    }
    exec_result_free(&result);
    return ok;
}

/* --------------------------------------------------------------- shutdown */

void guest_shutdown(Guest *guest) {
    guest->ready = false;

    if (guest->emulator_pid > 0) {
        /* Signal the whole process group: the emulator may have children. */
        kill(-guest->emulator_pid, SIGTERM);
        long deadline = now_ms() + SHUTDOWN_GRACE_MS;
        for (;;) {
            int status;
            pid_t done = waitpid(guest->emulator_pid, &status, WNOHANG);
            if (done == guest->emulator_pid || done < 0) {
                break;
            }
            if (now_ms() >= deadline) {
                kill(-guest->emulator_pid, SIGKILL);
                waitpid(guest->emulator_pid, &status, 0);
                break;
            }
            struct timespec nap = {.tv_sec = 0, .tv_nsec = 20 * 1000000L};
            nanosleep(&nap, NULL);
        }
        guest->emulator_pid = 0;
    }

    if (guest->to_guest >= 0) {
        close(guest->to_guest);
    }
    if (guest->from_guest >= 0 && guest->from_guest != guest->to_guest) {
        close(guest->from_guest);
    }
    guest->to_guest = -1;
    guest->from_guest = -1;

    if (guest->task_disk != NULL && !guest->config->keep_task_disk &&
        guest->config->task_disk_path == NULL) {
        unlink(guest->task_disk);
    }
}

void guest_free(Guest *guest) {
    buffer_free(&guest->pending);
    free(guest->task_disk);
    free(guest->last_error);
    memset(guest, 0, sizeof(*guest));
}
