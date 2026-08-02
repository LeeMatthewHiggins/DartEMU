/* Assertions for the agent's tests: no framework, just a failure counter. */
#ifndef AGENTOS_TEST_ASSERT_H
#define AGENTOS_TEST_ASSERT_H

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(condition, description)                                    \
    do {                                                                 \
        g_checks++;                                                      \
        if (!(condition)) {                                              \
            g_failures++;                                                \
            fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__,    \
                    (description));                                      \
        }                                                                \
    } while (0)

#define CHECK_STR_EQ(actual, expected, description)                      \
    do {                                                                 \
        g_checks++;                                                      \
        const char *a_ = (actual);                                       \
        const char *e_ = (expected);                                     \
        if (a_ == NULL || strcmp(a_, e_) != 0) {                         \
            g_failures++;                                                \
            fprintf(stderr, "  FAIL %s:%d: %s\n    expected: %s\n"       \
                            "    actual:   %s\n",                        \
                    __FILE__, __LINE__, (description), e_,               \
                    a_ != NULL ? a_ : "(null)");                         \
        }                                                                \
    } while (0)

#define CHECK_LONG_EQ(actual, expected, description)                     \
    do {                                                                 \
        g_checks++;                                                      \
        long a_ = (long)(actual);                                        \
        long e_ = (long)(expected);                                      \
        if (a_ != e_) {                                                  \
            g_failures++;                                                \
            fprintf(stderr, "  FAIL %s:%d: %s (expected %ld, got %ld)\n",\
                    __FILE__, __LINE__, (description), e_, a_);          \
        }                                                                \
    } while (0)

#define TEST_REPORT()                                                    \
    do {                                                                 \
        if (g_failures == 0) {                                           \
            printf("  %d checks passed\n", g_checks);                    \
            return 0;                                                    \
        }                                                                \
        fprintf(stderr, "  %d of %d checks failed\n", g_failures,        \
                g_checks);                                               \
        return 1;                                                        \
    } while (0)

#endif /* AGENTOS_TEST_ASSERT_H */
