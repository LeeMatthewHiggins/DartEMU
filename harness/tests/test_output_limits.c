#include <stdlib.h>
#include <string.h>

#include "test_assert.h"
#include "protocol.h"

/* Builds {"id":1,...,"stdout":"<n bytes of 'x'>"} */
static char *response_with_stdout(size_t bytes) {
    Buffer line;
    buffer_init(&line);
    buffer_append_str(&line, "{\"id\":1,\"exit_code\":0,\"stdout\":\"");
    for (size_t i = 0; i < bytes; i++) {
        buffer_append(&line, "x", 1);
    }
    buffer_append_str(&line, "\",\"timed_out\":false}");
    return line.data;
}

static void test_output_under_the_cap_is_untouched(void) {
    char *line = response_with_stdout(100);
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), 4096, &result),
          "small output decodes");
    CHECK_LONG_EQ(result.stdout_text.len, 100, "output is kept whole");
    CHECK(!result.stdout_truncated, "small output is not marked truncated");
    exec_result_free(&result);
    free(line);
}

static void test_output_over_the_cap_is_cut_and_marked(void) {
    const size_t cap = 256;
    char *line = response_with_stdout(4096);
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), cap, &result),
          "oversized output still decodes");
    CHECK(result.stdout_truncated, "oversized output is marked truncated");
    CHECK(result.stdout_text.len > cap,
          "the note is appended after the capped bytes");
    CHECK(strstr(result.stdout_text.data, "[output truncated") != NULL,
          "the model is told the output was cut");
    /* The retained payload is exactly the cap; the rest is the note. */
    CHECK(strncmp(result.stdout_text.data,
                  "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 32) == 0,
          "the first bytes are the real output");
    exec_result_free(&result);
    free(line);
}

static void test_each_stream_is_capped_separately(void) {
    Buffer line;
    buffer_init(&line);
    buffer_append_str(&line, "{\"id\":2,\"exit_code\":0,\"stdout\":\"");
    for (size_t i = 0; i < 1000; i++) buffer_append(&line, "o", 1);
    buffer_append_str(&line, "\",\"stderr\":\"");
    for (size_t i = 0; i < 10; i++) buffer_append(&line, "e", 1);
    buffer_append_str(&line, "\",\"timed_out\":false}");

    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line.data, line.len, 100, &result),
          "mixed output decodes");
    CHECK(result.stdout_truncated, "the large stream is truncated");
    CHECK(!result.stderr_truncated, "the small stream is left alone");
    CHECK_LONG_EQ(result.stderr_text.len, 10, "the small stream is intact");
    exec_result_free(&result);
    buffer_free(&line);
}

static void test_base64_output_is_capped_after_decoding(void) {
    /* 12 decoded bytes; the cap must apply to the decoded size, not the
     * encoded one, or the model would see a wrong-sized limit. */
    const char *line =
        "{\"id\":3,\"exit_code\":0,"
        "\"stdout_b64\":\"YWFhYWFhYWFhYWFh\",\"timed_out\":false}";
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), 4, &result),
          "base64 output decodes");
    CHECK(result.stdout_truncated, "decoded base64 is capped");
    CHECK(strncmp(result.stdout_text.data, "aaaa", 4) == 0,
          "exactly the cap is kept");
    exec_result_free(&result);
}

static void test_truncation_note_states_the_limit(void) {
    Buffer out;
    buffer_init(&out);
    CHECK(protocol_append_truncation_note(&out, 1024), "note is written");
    CHECK(strstr(out.data, "1024") != NULL,
          "the note names the byte limit that was applied");
    buffer_free(&out);
}

int main(void) {
    test_output_under_the_cap_is_untouched();
    test_output_over_the_cap_is_cut_and_marked();
    test_each_stream_is_capped_separately();
    test_base64_output_is_capped_after_decoding();
    test_truncation_note_states_the_limit();
    TEST_REPORT();
}
