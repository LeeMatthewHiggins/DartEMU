/* The shell tool: what it returns, and what it refuses to let a command do
 * to the machine it runs on. */
#include <stdlib.h>
#include <string.h>

#include "agentos.h"
#include "test_assert.h"

enum { GENEROUS = 1 << 20, SMALL = 256, ONE_SECOND = 1000 };

static void test_captures_output(void) {
    ShellResult result;
    shell_run("echo hello", NULL, ONE_SECOND * 10, GENEROUS, &result);
    CHECK_LONG_EQ(result.exit_code, 0, "a successful command exits zero");
    CHECK(strstr(result.output.data, "hello") != NULL, "stdout is captured");
    CHECK(!result.truncated, "short output is not truncated");
    CHECK(!result.timed_out, "a fast command does not time out");
    shell_result_free(&result);
}

static void test_captures_stderr_and_status(void) {
    ShellResult result;
    shell_run("echo problem >&2; exit 3", NULL, ONE_SECOND * 10, GENEROUS,
              &result);
    CHECK_LONG_EQ(result.exit_code, 3, "the exit status is reported");
    CHECK(strstr(result.output.data, "problem") != NULL,
          "stderr is captured alongside stdout");
    shell_result_free(&result);
}

static void test_runs_in_the_given_directory(void) {
    ShellResult result;
    shell_run("pwd", "/tmp", ONE_SECOND * 10, GENEROUS, &result);
    CHECK(strstr(result.output.data, "tmp") != NULL,
          "the command runs in the directory it was given");
    shell_result_free(&result);
}

/* The important one: a command that prints without end must not be able to
 * exhaust the machine. The bound is applied while reading, so the process is
 * stopped rather than merely having its output trimmed afterwards. */
static void test_endless_output_is_bounded(void) {
    ShellResult result;
    shell_run("yes abcdefghijklmnop", NULL, ONE_SECOND * 20, SMALL, &result);
    CHECK(result.truncated, "endless output is reported as truncated");
    CHECK(result.output.len < SMALL * 4,
          "the kept output stays near the limit rather than growing");
    CHECK(strstr(result.output.data, "truncated") != NULL,
          "the model is told the output was cut");
    shell_result_free(&result);
}

static void test_a_hanging_command_is_killed(void) {
    ShellResult result;
    shell_run("sleep 30", NULL, 300, GENEROUS, &result);
    CHECK(result.timed_out, "a command past its deadline is reported");
    CHECK(result.exit_code != 0, "a killed command does not look successful");
    shell_result_free(&result);
}

/* A timeout must take the whole process tree; a child that outlives its
 * parent would hold the pipe open and hang the agent. */
static void test_the_timeout_takes_children_too(void) {
    ShellResult result;
    shell_run("sleep 30 & sleep 30", NULL, 300, GENEROUS, &result);
    CHECK(result.timed_out, "the group is killed, not just the shell");
    shell_result_free(&result);
}

static void test_a_missing_directory_is_reported(void) {
    ShellResult result;
    shell_run("echo unreachable", "/no/such/place", ONE_SECOND * 10, GENEROUS,
              &result);
    CHECK(result.exit_code != 0, "an impossible directory fails the command");
    shell_result_free(&result);
}

/* Nothing here filters what may run: the machine is the boundary, not the
 * agent. A command that would be alarming anywhere else is simply run. */
static void test_nothing_is_filtered(void) {
    ShellResult result;
    shell_run("rm -rf /tmp/agentos-test-scratch && echo removed", NULL,
              ONE_SECOND * 10, GENEROUS, &result);
    CHECK_LONG_EQ(result.exit_code, 0, "a destructive command simply runs");
    shell_result_free(&result);
}

int main(void) {
    test_captures_output();
    test_captures_stderr_and_status();
    test_runs_in_the_given_directory();
    test_endless_output_is_bounded();
    test_a_hanging_command_is_killed();
    test_the_timeout_takes_children_too();
    test_a_missing_directory_is_reported();
    test_nothing_is_filtered();
    TEST_REPORT();
}
