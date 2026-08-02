#include <stdlib.h>
#include <string.h>

#include "harness_test.h"
#include "protocol.h"

static void test_request_encoding(void) {
    Buffer out;
    buffer_init(&out);
    ExecRequest request = {.id = 17,
                           .command = "make test",
                           .cwd = "/workspace",
                           .timeout_ms = 120000};
    CHECK(protocol_encode_request(&out, &request), "request encodes");
    /* The documented fields are present verbatim; the base64 companions ride
     * alongside for the shell daemon. */
    CHECK_STR_EQ(out.data,
                 "{\"id\":17,\"command\":\"make test\","
                 "\"command_b64\":\"bWFrZSB0ZXN0\","
                 "\"cwd\":\"/workspace\","
                 "\"cwd_b64\":\"L3dvcmtzcGFjZQ==\","
                 "\"timeout_ms\":120000}\n",
                 "request carries the documented fields and their encodings");
    buffer_free(&out);
}

static void test_request_passes_commands_through_unaltered(void) {
    /* The harness must never sanitise a command. Quotes, redirection,
     * backticks and rm -rf all have to survive the encoder untouched. */
    Buffer out;
    buffer_init(&out);
    const char *hostile =
        "rm -rf / --no-preserve-root; echo \"$(whoami)\" > /tmp/x && `id`";
    ExecRequest request = {.id = 1, .command = hostile};
    CHECK(protocol_encode_request(&out, &request), "hostile command encodes");

    JsonValue *parsed = json_parse(out.data);
    const JsonValue *command = json_object_get(parsed, "command");
    CHECK(command != NULL && command->type == JSON_STRING,
          "command survives as a string");
    if (command != NULL) {
        CHECK_STR_EQ(command->string, hostile,
                     "command reaches the guest byte for byte");
    }
    json_free(parsed);
    buffer_free(&out);
}

static void test_base64_command_survives_quotes(void) {
    /* A greedy field extractor in the guest daemon used to swallow every
     * field after the first quote in the command, so a quoted command ran as
     * something else entirely. The base64 companion removes the ambiguity. */
    Buffer out;
    buffer_init(&out);
    ExecRequest request = {
        .id = 2, .command = "echo \"hi\"", .cwd = "/tmp"};
    CHECK(protocol_encode_request(&out, &request), "quoted command encodes");

    JsonValue *parsed = json_parse(out.data);
    const JsonValue *encoded = json_object_get(parsed, "command_b64");
    CHECK(encoded != NULL && encoded->type == JSON_STRING,
          "command_b64 is present");
    if (encoded != NULL) {
        Buffer decoded;
        buffer_init(&decoded);
        CHECK(protocol_base64_decode(encoded->string, encoded->string_len,
                                     &decoded),
              "command_b64 decodes");
        CHECK_STR_EQ(decoded.data, "echo \"hi\"",
                     "the quoted command round-trips exactly");
        buffer_free(&decoded);
    }
    const JsonValue *cwd = json_object_get(parsed, "cwd_b64");
    CHECK(cwd != NULL, "cwd_b64 accompanies cwd");
    json_free(parsed);
    buffer_free(&out);
}

static void test_base64_encoder(void) {
    struct { const char *input; const char *expected; } cases[] = {
        {"", ""}, {"A", "QQ=="}, {"AB", "QUI="}, {"ABC", "QUJD"},
        {"hello world", "aGVsbG8gd29ybGQ="},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        Buffer out;
        buffer_init(&out);
        CHECK(protocol_base64_encode(cases[i].input, strlen(cases[i].input),
                                     &out),
              "encoding succeeds");
        CHECK_STR_EQ(out.data != NULL ? out.data : "", cases[i].expected,
                     "base64 matches the reference encoding");
        buffer_free(&out);
    }
}

static void test_optional_fields_are_omitted(void) {
    Buffer out;
    buffer_init(&out);
    ExecRequest request = {.id = 3, .command = "ls"};
    CHECK(protocol_encode_request(&out, &request), "minimal request encodes");
    CHECK(strstr(out.data, "\"cwd\"") == NULL, "absent cwd is omitted");
    CHECK(strstr(out.data, "cwd_b64") == NULL, "no cwd means no cwd_b64");
    CHECK(strstr(out.data, "timeout_ms") == NULL,
          "absent timeout is omitted so the daemon applies its default");
    buffer_free(&out);
}

static void test_response_decoding(void) {
    const char *line =
        "{\"id\":17,\"exit_code\":1,\"stdout\":\"test output\","
        "\"stderr\":\"error output\",\"timed_out\":false}";
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), 4096, &result),
          "documented response decodes");
    CHECK_LONG_EQ(result.id, 17, "id round-trips");
    CHECK_LONG_EQ(result.exit_code, 1, "exit code round-trips");
    CHECK_STR_EQ(result.stdout_text.data, "test output", "stdout round-trips");
    CHECK_STR_EQ(result.stderr_text.data, "error output", "stderr round-trips");
    CHECK(!result.timed_out, "timed_out round-trips");
    exec_result_free(&result);
}

static void test_base64_streams(void) {
    /* The shell daemon cannot escape arbitrary bytes into JSON, so it sends
     * base64; both spellings must decode to the same thing. */
    const char *line =
        "{\"id\":5,\"exit_code\":0,\"stdout_b64\":\"aGVsbG8gd29ybGQ=\","
        "\"stderr_b64\":\"\",\"timed_out\":false}";
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), 4096, &result),
          "base64 response decodes");
    CHECK_STR_EQ(result.stdout_text.data, "hello world", "base64 stdout decodes");
    CHECK_LONG_EQ(result.stderr_text.len, 0, "empty base64 stderr is empty");
    exec_result_free(&result);
}

static void test_binary_output_survives(void) {
    /* "\x00\x01\xff" base64-encodes to AAH/ */
    const char *line =
        "{\"id\":6,\"exit_code\":0,\"stdout_b64\":\"AAH/\",\"timed_out\":false}";
    ExecResult result;
    exec_result_init(&result);
    CHECK(protocol_decode_response(line, strlen(line), 4096, &result),
          "binary output decodes");
    CHECK_LONG_EQ(result.stdout_text.len, 3, "all three bytes survive");
    if (result.stdout_text.len == 3) {
        CHECK((unsigned char)result.stdout_text.data[0] == 0x00 &&
                  (unsigned char)result.stdout_text.data[1] == 0x01 &&
                  (unsigned char)result.stdout_text.data[2] == 0xFF,
              "NUL and high bytes are preserved");
    }
    exec_result_free(&result);
}

static void test_malformed_frames_report_errors(void) {
    struct {
        const char *line;
        const char *description;
    } cases[] = {
        {"not json at all", "plain text is rejected"},
        {"[1,2,3]", "a non-object is rejected"},
        {"{\"exit_code\":0}", "a response without an id is rejected"},
        {"{\"id\":\"seven\"}", "a non-numeric id is rejected"},
        {"{\"id\":1,\"stdout\":42}", "a non-string stdout is rejected"},
        {"{\"id\":1,\"stdout_b64\":\"!!!!\"}", "invalid base64 is rejected"},
        {"{\"id\":1,", "a truncated object is rejected"},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        ExecResult result;
        exec_result_init(&result);
        bool ok = protocol_decode_response(cases[i].line,
                                           strlen(cases[i].line), 4096, &result);
        CHECK(!ok, cases[i].description);
        CHECK(result.transport_error, "a rejected frame sets a transport error");
        CHECK(result.error_message != NULL,
              "a rejected frame explains what was wrong");
        exec_result_free(&result);
    }
}

static void test_base64_decoder(void) {
    struct {
        const char *input;
        const char *expected;
    } cases[] = {
        {"", ""},
        {"QQ==", "A"},
        {"QUI=", "AB"},
        {"QUJD", "ABC"},
        {"QUJD\nRA==", "ABCD"}, /* embedded newlines are tolerated */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        Buffer out;
        buffer_init(&out);
        CHECK(protocol_base64_decode(cases[i].input, strlen(cases[i].input),
                                     &out),
              "valid base64 decodes");
        CHECK_STR_EQ(out.data != NULL ? out.data : "", cases[i].expected,
                     "base64 decodes to the expected bytes");
        buffer_free(&out);
    }

    Buffer out;
    buffer_init(&out);
    CHECK(!protocol_base64_decode("A@BC", 4, &out),
          "an invalid character is rejected");
    buffer_free(&out);
}

static void test_json_escaping(void) {
    Buffer out;
    buffer_init(&out);
    const char raw[] = "line\nquote\"tab\tbackslash\\";
    CHECK(json_write_string(&out, raw, strlen(raw)), "escaping succeeds");
    JsonValue *parsed = json_parse(out.data);
    CHECK(parsed != NULL && parsed->type == JSON_STRING,
          "escaped output parses back");
    if (parsed != NULL) {
        CHECK_STR_EQ(parsed->string, raw, "escaping round-trips");
    }
    json_free(parsed);
    buffer_free(&out);

    /* Invalid UTF-8 must not produce a document a strict parser rejects. */
    buffer_init(&out);
    const char invalid[] = {(char)0xC3, (char)0x28, '\0'};
    CHECK(json_write_string(&out, invalid, 2), "invalid UTF-8 is escaped");
    parsed = json_parse(out.data);
    CHECK(parsed != NULL, "invalid UTF-8 still yields parseable JSON");
    json_free(parsed);
    buffer_free(&out);
}

int main(void) {
    test_request_encoding();
    test_request_passes_commands_through_unaltered();
    test_base64_command_survives_quotes();
    test_base64_encoder();
    test_optional_fields_are_omitted();
    test_response_decoding();
    test_base64_streams();
    test_binary_output_survives();
    test_malformed_frames_report_errors();
    test_base64_decoder();
    test_json_escaping();
    TEST_REPORT();
}
