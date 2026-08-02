/* AgentEMU: an AI terminal.
 *
 * Where a terminal gives you a shell, this gives you the agent. You type in
 * plain language; the agent has the shell, inside the disposable guest.
 */
#ifndef HARNESS_INTERACTIVE_H
#define HARNESS_INTERACTIVE_H

#include <signal.h>
#include <stdbool.h>

#include "config.h"
#include "guest.h"
#include "transcript.h"

/* Reads a line from stdin with terminal echo disabled, for secrets.
 * Returns a heap string the caller owns, or NULL at end of input. */
char *interactive_read_secret(const char *prompt);

/* Reads a visible line from stdin. NULL at end of input. */
char *interactive_read_line(const char *prompt);

/* Asks for an API key when the configuration has none, so the first thing
 * AgentEMU does is exactly what a machine asking to be logged into does.
 * Returns false when the user declines to provide one. */
bool interactive_prompt_for_api_key(Config *config);

/* Runs the conversation loop until the user leaves, the guest is lost, or a
 * budget is exhausted. Returns a process exit status. */
int interactive_run(const Config *config, Guest *guest, Transcript *transcript,
                    const volatile sig_atomic_t *interrupted);

#endif /* HARNESS_INTERACTIVE_H */
