#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentos.h"

enum { INPUT_CHUNK = 512 };

/* Built from the configuration rather than hard-coded, so what the model is
 * told matches the machine it actually has. The detail lives at /llms.txt;
 * this stays short and points there. */
char *agent_system_prompt(const AgentConfig *config) {
    Buffer prompt;
    buffer_init(&prompt);
    buffer_append_str(
        &prompt,
        "You are AgentOS, running inside a disposable emulated RISC-V Linux "
        "machine. You are root and completely free: install, modify, delete "
        "or reconfigure anything. The machine is destroyed when the session "
        "ends and nothing you do can reach the host.\n\n"
        "You have exactly one tool: 'shell', which runs a command on this "
        "machine. There is no file-editing tool and no browser — use the "
        "shell for everything.\n\n"
        "Read /llms.txt first. It indexes short notes on the environment and "
        "on what is expensive here.\n\n");

    buffer_append_str(&prompt,
                      "This is an emulated CPU, so work is not free:\n");
    buffer_printf(&prompt,
                  "- Command output is truncated at %zu bytes. Truncation is "
                  "reported; the lost bytes are gone.\n",
                  config->max_output);
    buffer_printf(&prompt, "- A command is killed after %ld seconds.\n",
                  config->command_timeout_ms / 1000);
    buffer_append_str(
        &prompt,
        "- Measure before you list. `du -sh dir`, `find dir -maxdepth 1`, "
        "`wc -l` and `| head` are cheap; printing a whole tree is not.\n\n");

    buffer_append_str(
        &prompt,
        "This machine reaches the network only through its host, which "
        "allows a fixed set of destinations and holds every credential. Your "
        "own requests carry a placeholder, never a key, so there is no secret "
        "here for you or anyone else to find. If a request is refused, the "
        "reason says so plainly; report it rather than trying to work around "
        "it.\n\n");

    buffer_append_str(
        &prompt,
        "Work in /workspace unless told otherwise. When you are done, reply "
        "with a plain message and no tool call, saying what you did and what "
        "you found.");

    return prompt.data;
}

/* Renders a result the way the model sees it: exit status first, then the
 * output, with truncation and timeouts stated rather than implied. */
bool agent_format_result(const ShellResult *result, Buffer *out) {
    if (!buffer_printf(out, "exit_code: %d\n", result->exit_code)) {
        return false;
    }
    if (result->timed_out && !buffer_append_str(out, "timed_out: true\n")) {
        return false;
    }
    if (result->output.len == 0) {
        return buffer_append_str(out, "\n(no output)\n");
    }
    return buffer_append_str(out, "\n--- output ---\n") &&
           buffer_append(out, result->output.data, result->output.len);
}

/* Reads one line of any length. Returns NULL at end of input. */
static char *read_line(void) {
    Buffer line;
    buffer_init(&line);
    for (;;) {
        char chunk[INPUT_CHUNK];
        if (fgets(chunk, sizeof(chunk), stdin) == NULL) {
            bool empty = line.len == 0;
            if (empty) {
                buffer_free(&line);
                return NULL;
            }
            return line.data;
        }
        size_t len = strlen(chunk);
        bool complete = len > 0 && chunk[len - 1] == '\n';
        if (complete) {
            len--;
        }
        if (!buffer_append(&line, chunk, len)) {
            buffer_free(&line);
            return NULL;
        }
        if (complete) {
            return line.data != NULL ? line.data : strdup("");
        }
    }
}

static bool is_blank(const char *text) {
    for (const char *c = text; *c != '\0'; c++) {
        if (*c != ' ' && *c != '\t' && *c != '\r') {
            return false;
        }
    }
    return true;
}

/* Runs one question to completion, printing the work as it happens.
 * Returns false only when the session should end. */
static bool run_turn(const AgentConfig *config, Conversation *conversation,
                     const char *question) {
    if (!conversation_add_text(conversation, "user", question)) {
        printf("This machine has run out of memory.\n");
        return false;
    }

    for (long step = 0; step < config->max_steps; step++) {
        LlmReply reply;
        char *error = NULL;
        if (!llm_complete(config, conversation, &reply, &error)) {
            printf("\n%s\n\n",
                   error != NULL ? error : "the model could not be reached");
            free(error);
            return true; /* the session survives a failed call */
        }

        if (reply.raw_message != NULL) {
            conversation_add_raw(conversation, reply.raw_message);
        }
        if (reply.content != NULL && reply.content[0] != '\0') {
            printf("\n%s\n", reply.content);
            fflush(stdout);
        }

        if (!reply.has_tool_calls) {
            printf("\n");
            llm_reply_free(&reply);
            return true;
        }

        for (size_t i = 0; i < reply.tool_call_count; i++) {
            const ToolCall *call = &reply.tool_calls[i];

            if (call->decode_error != NULL) {
                /* A malformed tool call is the model's mistake to correct,
                 * not a reason to end the turn. */
                printf("  ! %s\n", call->decode_error);
                conversation_add_tool_result(conversation, call->id,
                                             call->decode_error,
                                             strlen(call->decode_error));
                continue;
            }

            printf("  $ %s\n", call->command);
            fflush(stdout);

            ShellResult result;
            shell_run(call->command, call->cwd, call->timeout_ms,
                      config->max_output, &result);

            Buffer rendered;
            buffer_init(&rendered);
            if (agent_format_result(&result, &rendered)) {
                conversation_add_tool_result(conversation, call->id,
                                             rendered.data, rendered.len);
            }
            buffer_free(&rendered);

            if (result.output.len > 0) {
                fwrite(result.output.data, 1, result.output.len, stdout);
                if (result.output.data[result.output.len - 1] != '\n') {
                    printf("\n");
                }
            }
            if (result.timed_out) {
                printf("  ! the command was killed after %ld seconds\n",
                       call->timeout_ms / 1000);
            }
            fflush(stdout);
            shell_result_free(&result);
        }

        llm_reply_free(&reply);
    }

    printf("\nStopped after %ld steps without a final answer. Ask again to "
           "continue.\n\n",
           config->max_steps);
    return true;
}

int agent_main(const AgentConfig *config) {
    Conversation conversation;
    conversation_init(&conversation);

    char *prompt = agent_system_prompt(config);
    if (prompt != NULL) {
        conversation_add_text(&conversation, "system", prompt);
        free(prompt);
    }

    for (;;) {
        printf("> ");
        fflush(stdout);
        char *line = read_line();
        if (line == NULL) {
            break;
        }
        if (is_blank(line)) {
            free(line);
            continue;
        }
        bool go_on = run_turn(config, &conversation, line);
        free(line);
        if (!go_on) {
            break;
        }
    }

    conversation_free(&conversation);
    return 0;
}
