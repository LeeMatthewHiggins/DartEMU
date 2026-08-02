#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "agentos.h"

enum { READ_CHUNK = 4096, POLL_SLICE_MS = 100 };

void shell_result_init(ShellResult *result) {
    memset(result, 0, sizeof(*result));
    buffer_init(&result->output);
    result->exit_code = -1;
}

void shell_result_free(ShellResult *result) { buffer_free(&result->output); }

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

/* Runs the command with stdout and stderr on one pipe.
 *
 * The output bound is applied as the pipe is drained rather than afterwards:
 * a command that prints without end would otherwise fill memory or the disk
 * long before anyone could truncate the result.
 */
void shell_run(const char *command, const char *cwd, long timeout_ms,
               size_t max_output, ShellResult *result) {
    shell_result_init(result);

    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        buffer_append_str(&result->output, "could not create a pipe");
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        buffer_append_str(&result->output, "could not fork");
        return;
    }

    if (pid == 0) {
        close(pipe_fds[0]);
        dup2(pipe_fds[1], STDOUT_FILENO);
        dup2(pipe_fds[1], STDERR_FILENO);
        close(pipe_fds[1]);
        if (cwd != NULL && cwd[0] != '\0') {
            if (chdir(cwd) != 0) {
                _exit(126);
            }
        }
        /* Its own process group, so a timeout can take the whole tree. */
        setpgid(0, 0);
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }

    close(pipe_fds[1]);

    const long deadline = now_ms() + (timeout_ms > 0 ? timeout_ms : 120000);
    bool killed = false;

    for (;;) {
        struct pollfd pfd = {.fd = pipe_fds[0], .events = POLLIN};
        long remaining = deadline - now_ms();
        if (remaining <= 0 && !killed) {
            kill(-pid, SIGKILL);
            killed = true;
            result->timed_out = true;
            remaining = POLL_SLICE_MS;
        }
        int slice = (int)(remaining < POLL_SLICE_MS ? remaining
                                                    : POLL_SLICE_MS);
        int ready = poll(&pfd, 1, slice < 0 ? POLL_SLICE_MS : slice);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (ready == 0) {
            continue;
        }

        char chunk[READ_CHUNK];
        ssize_t got = read(pipe_fds[0], chunk, sizeof(chunk));
        if (got <= 0) {
            break; /* the child closed the pipe */
        }
        size_t room = result->output.len < max_output
                          ? max_output - result->output.len
                          : 0;
        if (room == 0) {
            result->truncated = true;
            if (!killed) {
                /* Nothing more will be kept, so stop paying for it. */
                kill(-pid, SIGKILL);
                killed = true;
            }
            continue;
        }
        size_t keep = (size_t)got < room ? (size_t)got : room;
        if (keep < (size_t)got) {
            result->truncated = true;
        }
        buffer_append(&result->output, chunk, keep);
    }

    close(pipe_fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        result->exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        result->exit_code = 128 + WTERMSIG(status);
    }

    if (result->truncated) {
        buffer_printf(&result->output,
                      "\n[output truncated at %zu bytes]\n", max_output);
    }
}
