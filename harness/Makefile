CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Wpedantic -Wshadow
CFLAGS += -Iinclude -I../common -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE
LDLIBS_CURL ?= -lcurl

BUILD := build
SRC := src
TESTS := tests

COMMON := ../common
CORE_SRC := $(COMMON)/json.c $(COMMON)/chat.c $(SRC)/protocol.c $(SRC)/config.c \
            $(SRC)/transcript.c $(SRC)/guest.c $(SRC)/agent.c \
            $(SRC)/interactive.c
HARNESS_SRC := $(CORE_SRC) $(SRC)/llm.c $(SRC)/main.c

TEST_BINS := $(BUILD)/test_protocol $(BUILD)/test_agent_loop \
             $(BUILD)/test_output_limits $(BUILD)/test_session

.PHONY: all test clean

all: $(BUILD)/harness

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/harness: $(HARNESS_SRC) | $(BUILD)
	$(CC) $(CFLAGS) $(HARNESS_SRC) -o $@ $(LDLIBS_CURL) -lm

# Tests link the same sources with the HTTP client stubbed out, so they need
# no network and no libcurl.
$(BUILD)/test_%: $(TESTS)/test_%.c $(CORE_SRC) $(SRC)/llm.c | $(BUILD)
	$(CC) $(CFLAGS) -DHARNESS_NO_CURL $< $(CORE_SRC) $(SRC)/llm.c -o $@ -lm

test: $(TEST_BINS)
	@set -e; for t in $(TEST_BINS); do echo "== $$t"; $$t; done
	@echo "all harness tests passed"

clean:
	rm -rf $(BUILD)
