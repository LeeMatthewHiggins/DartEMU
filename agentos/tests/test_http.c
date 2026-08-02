/* Reading what the host proxy sends back. */
#include <string.h>

#include "agentos.h"
#include "harness_test.h"

static void test_splits_status_from_body(void) {
    const char *raw =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        "Content-Length: 9\r\n\r\n{\"ok\":1}\n";
    int status = 0;
    const char *body = NULL;
    size_t body_len = 0;
    CHECK(http_split_response(raw, strlen(raw), &status, &body, &body_len),
          "a well-formed response is read");
    CHECK_LONG_EQ(status, 200, "the status is read");
    CHECK_LONG_EQ(body_len, 9, "the body length is the bytes after the head");
    CHECK(strncmp(body, "{\"ok\":1}", 8) == 0, "the body starts where it should");
}

/* A refusal carries a body worth reading, so an error status must not cause
 * the body to be discarded. */
static void test_an_error_status_still_yields_its_body(void) {
    const char *raw =
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n"
        "{\"error\":{\"message\":\"No credential is configured for KEY.\"}}";
    int status = 0;
    const char *body = NULL;
    size_t body_len = 0;
    CHECK(http_split_response(raw, strlen(raw), &status, &body, &body_len),
          "the response is read");
    CHECK_LONG_EQ(status, 401, "the status is read");
    CHECK(strstr(body, "No credential") != NULL, "the reason survives");
}

/* A body containing a blank line must not be split at the wrong place. */
static void test_splits_at_the_first_blank_line_only(void) {
    const char *raw = "HTTP/1.1 200 OK\r\n\r\nfirst\r\n\r\nsecond";
    int status = 0;
    const char *body = NULL;
    size_t body_len = 0;
    CHECK(http_split_response(raw, strlen(raw), &status, &body, &body_len),
          "the response is read");
    CHECK_STR_EQ(body, "first\r\n\r\nsecond",
                 "the whole body is kept, blank lines and all");
}

static void test_rejects_what_is_not_http(void) {
    int status = 0;
    const char *body = NULL;
    size_t body_len = 0;
    const char *garbage = "this is not a response at all";
    CHECK(!http_split_response(garbage, strlen(garbage), &status, &body,
                               &body_len),
          "non-HTTP is refused rather than misread");

    const char *headless = "HTTP/1.1 200 OK\r\nContent-Type: text/plain";
    CHECK(!http_split_response(headless, strlen(headless), &status, &body,
                               &body_len),
          "a response with no end of headers is refused");

    CHECK(!http_split_response("", 0, &status, &body, &body_len),
          "an empty response is refused");
}

int main(void) {
    test_splits_status_from_body();
    test_an_error_status_still_yields_its_body();
    test_splits_at_the_first_blank_line_only();
    test_rejects_what_is_not_http();
    TEST_REPORT();
}
