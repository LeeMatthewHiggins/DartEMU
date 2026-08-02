# AgentOS: the agent that runs inside the machine.
#
# Two builds from one set of sources. The host build exists so the logic can
# be tested at native speed; the riscv64 build is the one that goes into the
# image, and it is static because the guest has no shared libraries to spare.

CC ?= cc
CROSS_CC ?= riscv64-linux-gnu-gcc

CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Wpedantic -Wshadow
CFLAGS += -Iinclude -I../harness/include -I../harness/tests \
          -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE

BUILD := build
SRC := src
TESTS := tests
JSON := ../harness/src/json.c

CORE_SRC := $(JSON) $(SRC)/shell.c $(SRC)/http.c $(SRC)/llm.c $(SRC)/agent.c
AGENTOS_SRC := $(CORE_SRC) $(SRC)/main.c

TEST_BINS := $(BUILD)/test_shell $(BUILD)/test_llm $(BUILD)/test_http

.PHONY: all guest test clean

all: $(BUILD)/agentos

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/agentos: $(AGENTOS_SRC) | $(BUILD)
	$(CC) $(CFLAGS) $(AGENTOS_SRC) -o $@

# The binary that ships in the image. Static so it depends on nothing the
# guest might not have.
guest: $(AGENTOS_SRC) | $(BUILD)
	$(CROSS_CC) $(CFLAGS) -static $(AGENTOS_SRC) -o $(BUILD)/agentos-riscv64
	@ls -l $(BUILD)/agentos-riscv64

$(BUILD)/test_%: $(TESTS)/test_%.c $(CORE_SRC) | $(BUILD)
	$(CC) $(CFLAGS) $< $(CORE_SRC) -o $@

test: $(TEST_BINS)
	@set -e; for t in $(TEST_BINS); do echo "== $$t"; $$t; done
	@echo "all agentos tests passed"

clean:
	rm -rf $(BUILD)
