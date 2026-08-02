#include "interactive.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "agent.h"
#include "llm.h"

enum { LINE_CHUNK = 256, PREVIEW_MAX = 72 };

/* Colours are used only when stdout is a terminal, so a redirected session
 * produces a clean log. */
static const char *C_DIM = "";
static const char *C_BOLD = "";
static const char *C_AGENT = "";
static const char *C_RESET = "";

static void enable_colour_if_tty(void) {
    if (isatty(STDOUT_FILENO)) {
        C_DIM = "\033[2m";
        C_BOLD = "\033[1m";
        C_AGENT = "\033[36m";
        C_RESET = "\033[0m";
    }
}

/* ------------------------------------------------------------------ input */

static char *read_line_from(FILE *stream) {
    Buffer line;
    buffer_init(&line);
    int c;
    bool any = false;
    while ((c = fgetc(stream)) != EOF) {
        any = true;
        if (c == '\n') {
            break;
        }
        char ch = (char)c;
        if (!buffer_append(&line, &ch, 1)) {
            buffer_free(&line);
            return NULL;
        }
    }
    if (!any && c == EOF) {
        buffer_free(&line);
        return NULL;
    }
    if (line.data == NULL) {
        return calloc(1, 1);
    }
    return line.data;
}

char *interactive_read_line(const char *prompt) {
    if (prompt != NULL) {
        fputs(prompt, stdout);
        fflush(stdout);
    }
    return read_line_from(stdin);
}

char *interactive_read_secret(const char *prompt) {
    if (prompt != NULL) {
        fputs(prompt, stdout);
        fflush(stdout);
    }

    struct termios original;
    bool restored = false;
    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &original) == 0) {
        struct termios quiet = original;
        quiet.c_lflag &= (tcflag_t)~ECHO;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0) {
            restored = true;
        }
    }

    char *line = read_line_from(stdin);

    if (restored) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original);
        fputs("\n", stdout);
    }
    return line;
}

/* Trims leading and trailing spaces in place, returning the start. */
static char *trim(char *text) {
    while (*text == ' ' || *text == '\t' || *text == '\r') {
        text++;
    }
    size_t len = strlen(text);
    while (len > 0 && (text[len - 1] == ' ' || text[len - 1] == '\t' ||
                       text[len - 1] == '\r')) {
        text[--len] = '\0';
    }
    return text;
}

bool interactive_prompt_for_api_key(Config *config) {
    if (config->api_key != NULL && config->api_key[0] != '\0') {
        return true;
    }
    printf("%sThis machine needs an API key to think with.%s\n", C_DIM,
           C_RESET);
    printf("%sIt stays on the host: it is never written to the transcript "
           "and never enters the guest.%s\n\n",
           C_DIM, C_RESET);

    char *key = interactive_read_secret("API key: ");
    if (key == NULL) {
        return false;
    }
    char *trimmed = trim(key);
    if (trimmed[0] == '\0') {
        free(key);
        fprintf(stderr, "harness: no API key given\n");
        return false;
    }
    free(config->api_key);
    config->api_key = strdup(trimmed);
    free(key);
    return config->api_key != NULL;
}

/* --------------------------------------------------------------- progress */

/* Shows the command on one line, then completes that line with the outcome,
 * so the transcript on screen reads like work being done. */
static void on_tool_call(void *user, const char *command, const char *cwd) {
    (void)user;
    char preview[PREVIEW_MAX + 4];
    size_t len = strlen(command);
    if (len > PREVIEW_MAX) {
        memcpy(preview, command, PREVIEW_MAX);
        memcpy(preview + PREVIEW_MAX, "...", 4);
    } else {
        memcpy(preview, command, len + 1);
    }
    /* Newlines in a command would break the single-line shape. */
    for (char *p = preview; *p != '\0'; p++) {
        if (*p == '\n' || *p == '\r') {
            *p = ' ';
        }
    }
    if (cwd != NULL) {
        printf("  %s$ %s%s %s(in %s)%s", C_DIM, preview, C_RESET, C_DIM, cwd,
               C_RESET);
    } else {
        printf("  %s$ %s%s", C_DIM, preview, C_RESET);
    }
    fflush(stdout);
}

static void on_tool_result(void *user, const ExecResult *result,
                           long duration_ms) {
    (void)user;
    if (result->transport_error) {
        printf("  %s[transport error]%s\n", C_DIM, C_RESET);
    } else if (result->timed_out) {
        printf("  %s[timed out after %ldms]%s\n", C_DIM, duration_ms, C_RESET);
    } else {
        printf("  %s[exit %d, %ldms]%s\n", C_DIM, result->exit_code,
               duration_ms, C_RESET);
    }
    fflush(stdout);
}

/* ------------------------------------------------------------------- loop */

static void print_banner(const Config *config) {
    printf("\n%sAgentEMU%s — an AI terminal\n", C_BOLD, C_RESET);
    printf("%sYou talk; the agent has the shell, inside a disposable "
           "machine.%s\n",
           C_DIM, C_RESET);
    printf("%sModel %s · network %s · %ld steps · %lds%s\n", C_DIM,
           config->model, config_network_mode_name(config->network_mode),
           config->max_agent_steps, config->max_task_seconds, C_RESET);
    printf("%sType /help for commands, /exit to leave.%s\n\n", C_DIM, C_RESET);
}

static void print_help(void) {
    printf("  %s/help%s     show this\n", C_BOLD, C_RESET);
    printf("  %s/exit%s     end the session and destroy the machine\n", C_BOLD,
           C_RESET);
    printf("  %s/steps%s    how much of the budget is left\n", C_BOLD, C_RESET);
    printf("\n  Anything else is sent to the agent.\n\n");
}

int interactive_run(const Config *config, Guest *guest, Transcript *transcript,
                    const volatile sig_atomic_t *interrupted) {
    enable_colour_if_tty();
    print_banner(config);

    /* One mutable copy, so a session-wide budget can be reported accurately
     * without the caller's configuration being altered. */
    AgentSession session;
    agent_session_init(&session);

    AgentHooks hooks = {.on_tool_call = on_tool_call,
                        .on_tool_result = on_tool_result};

    int status = EXIT_SUCCESS;
    for (;;) {
        if (interrupted != NULL && *interrupted != 0) {
            printf("\n%sinterrupted%s\n", C_DIM, C_RESET);
            break;
        }

        char *raw = interactive_read_line("› ");
        if (raw == NULL) {
            printf("\n");
            break; /* end of input */
        }
        char *line = trim(raw);

        if (line[0] == '\0') {
            free(raw);
            continue;
        }
        if (strcmp(line, "/exit") == 0 || strcmp(line, "/quit") == 0) {
            free(raw);
            break;
        }
        if (strcmp(line, "/help") == 0) {
            print_help();
            free(raw);
            continue;
        }
        if (strcmp(line, "/steps") == 0) {
            printf("  %s%ld of %ld steps used%s\n\n", C_DIM, session.steps_used,
                   config->max_agent_steps, C_RESET);
            free(raw);
            continue;
        }

        AgentOutcome outcome = agent_session_ask(
            &session, config, guest, transcript, &hooks, interrupted, line);
        free(raw);

        if (outcome.final_answer != NULL && outcome.final_answer[0] != '\0') {
            printf("\n%s%s%s\n\n", C_AGENT, outcome.final_answer, C_RESET);
        }

        if (outcome.reason != AGENT_FINAL_ANSWER) {
            const char *explanation;
            switch (outcome.reason) {
                case AGENT_STEP_LIMIT:
                    explanation = "the step budget is spent";
                    break;
                case AGENT_TIME_LIMIT:
                    explanation = "the time budget is spent";
                    break;
                case AGENT_LLM_FAILED:
                    explanation = "the model could not be reached";
                    break;
                case AGENT_GUEST_LOST:
                    explanation = "the machine is gone";
                    break;
                case AGENT_INTERRUPTED:
                    explanation = "interrupted";
                    break;
                default:
                    explanation = "stopped";
                    break;
            }
            printf("%s— %s —%s\n\n", C_DIM, explanation, C_RESET);
            agent_outcome_free(&outcome);
            /* Budgets and a lost guest are terminal; a single failed API call
             * is not worth throwing the session away over. */
            if (outcome.reason != AGENT_LLM_FAILED) {
                status = EXIT_FAILURE;
                break;
            }
            continue;
        }
        agent_outcome_free(&outcome);
    }

    transcript_write_end(transcript, "session_ended", session.steps_used, 0,
                         NULL);
    agent_session_free(&session);
    printf("%sdestroying the machine%s\n", C_DIM, C_RESET);
    return status;
}
