# Minimal emulator-based agent harness

A small C program that gives a language model unrestricted control of a
disposable emulated machine. It sends conversation context to an
OpenAI-compatible API, receives a shell command through a single tool, runs it
inside the guest, and returns stdout, stderr, exit status and timeout state
until the model answers or a limit is reached.

**The emulator is the security boundary, not this harness.** There are no
command allowlists, no path restrictions, no shell filtering, no approval
prompts. The agent has total freedom inside the guest and no authority over
the host beyond what the emulator is given.

## Build

```sh
cd harness
make          # needs a C11 compiler and libcurl
make test     # unit tests; no network, no emulator
```

## Run

```sh
export LLM_API_KEY=sk-...
./build/harness \
  --task "Inspect the project in /workspace. Find and fix the failing tests. Run the test suite. Explain the changes made." \
  --kernel ../example/assets/kernel-riscv64.bin \
  --bios ../example/assets/bbl64.bin \
  --base-disk ../example/assets/root-riscv64.bin \
  --transcript task.jsonl \
  --artifacts workspace.tar
```

`--help` lists every option. All of them also have an environment variable.

## AgentEMU: an AI terminal

Where a terminal gives you a shell, AgentEMU gives you the agent. You type in
plain language; the agent has the shell, inside the disposable machine.

```sh
./build/harness --interactive \
  --kernel ../example/assets/kernel-riscv64.bin \
  --bios ../example/assets/bbl64.bin \
  --base-disk ../example/assets/root-riscv64.bin
```

The first thing it does is ask for an API key, with terminal echo off. The key
stays on the host: it is never written to the transcript and never enters the
guest. Set `LLM_API_KEY` to skip the prompt.

```
AgentEMU — an AI terminal
You talk; the agent has the shell, inside a disposable machine.
Model openai/gpt-4o · network none · 20 steps · 1800s
Type /help for commands, /exit to leave.

› create a file /workspace/hello.txt containing the word banana
  $ echo "banana" > /workspace/hello.txt  [exit 0, 270ms]

I created a file named `hello.txt` in the `/workspace` directory containing
the word "banana".

› what single word is in the file you just created?
  $ cat /workspace/hello.txt  [exit 0, 258ms]

The word in the file `hello.txt` is "banana".

› /exit
destroying the machine
```

Each command is shown as it runs, with its exit code and duration, so the
session reads as work being done rather than a pause.

One conversation and one machine last the whole session: the agent remembers
what it did, and what it created is still there. The step and time budgets
span the session rather than resetting per question, so a long conversation
cannot outlive them. `/help`, `/steps` and `/exit` are handled locally;
everything else goes to the agent.

## How it fits together

```
LLM API
   |
   v
agent.c        the loop: model, tool call, result, repeat
   |
   v
guest.c        task disk, emulator process, daemon install, request/response
   |
   v
dart_emu run   the emulated machine
   |
   v
host OS        where containment actually has to be enforced
```

The harness spawns `dart_emu run` and speaks to the guest over its console
pipes. `--serial <device>` attaches to an existing serial device instead, for
setups where the emulator is supervised separately.

## Guest execution protocol

Newline-delimited JSON, one object per line, in both directions.

```
{"id":17,"command":"make test","cwd":"/workspace","timeout_ms":120000}
{"id":17,"exit_code":1,"stdout":"...","stderr":"...","timed_out":false}
```

Requests also carry `command_b64` and `cwd_b64`, and responses may use
`stdout_b64` and `stderr_b64`. This is not decoration. The guest daemon is a
POSIX shell script, and a shell cannot reliably unescape a JSON string or
escape arbitrary command output into one:

- A greedy field extractor reading `"command"` swallowed everything up to the
  last quote on the line, so `echo "hi"` with a `cwd` ran as
  `echo "hi","cwd":"/tmp"`. Base64 has no quotes, so there is nothing to
  mis-parse.
- Command output is arbitrary bytes, including NUL and invalid UTF-8, which
  cannot be placed in a JSON string from a shell script at all.

The documented plain fields stay on the wire, so a richer daemon can use them
and ignore the encoded companions.

Guest output is treated as untrusted throughout: malformed frames produce an
error response rather than a crash, and every stream is capped at
`--max-output` bytes with truncation stated explicitly to the model.

## Guest daemon

Installed over the console at session start, so the shipped guest images need
no rebuild. It reads one request per line, runs the command with `sh`, and
answers with one response per line. Its readiness banner is what tells the
harness the guest is genuinely executing commands rather than merely booted.

A response must carry an `exit_code`. That requirement is what keeps the
console echo of the harness's own request — valid JSON, matching `id`, no
exit code — from being read as the guest's answer, which otherwise made every
command report exit -1 with no output.

The daemon is installed only once the console shows a shell prompt. A prompt
has no trailing newline, so it cannot be waited for with a line reader;
writing to a still-booting kernel loses the script entirely.

Per-command timeouts use a watchdog subshell. The timeout marker is written
*before* the kill: the parent's `wait` returns the instant the child dies and
kills the watchdog next, so marking afterwards loses the race and a timeout
reports as a plain failure.

## Verified end to end

Against the shipped RV64 image, a seeded `/workspace` containing a C project
with an off-by-one bug, and `openai/gpt-4o`:

```
$ ls /workspace                    -> README run_tests.sh sum.c test_sum.c
$ cat /workspace/run_tests.sh      -> exit 0
$ cat /workspace/test_sum.c        -> exit 0
$ cat /workspace/sum.c             -> exit 0
$ sed -i 's/i < n/i <= n/' ...     -> exit 0
$ /workspace/run_tests.sh          -> exit 0, all tests passed
```

The base image was byte-identical afterwards, the task disk was removed, and
the exported tar contained the corrected source.

## Task lifecycle

1. Copy the base disk to a task disk. DartEMU writes a file-backed drive
   through to the host file, so this copy is what makes the guest disposable —
   the base image is never opened for writing.
2. Start the emulator, wait for the daemon banner.
3. Run the agent loop, recording every command and result.
4. Export the workspace, if `--artifacts` was given.
5. Kill the emulator's process group and delete the task disk.

The loop stops on a final answer, the step limit, the wall-clock limit,
repeated API failure, a lost guest, or SIGINT.

## Transcript

JSON Lines, flushed after every record so an interrupted run still leaves an
auditable file. `task_start`, `tool_call`, `tool_result`, `assistant`,
`error`, `task_end`. The API key is never written to it and never reaches the
guest.

## What is deliberately absent

Per the design test — *can this be enforced more safely and generically by the
emulator, guest image or host supervisor?* — the harness does not implement
command filtering, path restrictions, permission prompts, or any
command-specific security logic. CPU, memory, disk, process and network
limits belong to the host supervisor that runs the emulator, not here.

Network modes are `none` and `full` only; `proxy` and `allowlist` are host
concerns and are rejected rather than silently downgraded.

## Deviations from the specification

- **No vendored JSON library.** `../common/json.c` is a self-contained reader
  and writer, about 550 lines, which is inside the specification's own budget
  for protocol and JSON and avoids adding third-party source and its licence
  bookkeeping to the tree. It sits in `common/` because the in-guest agent in
  [`agentos/`](../agentos) reads the same wire format, alongside `chat.c`,
  which holds the conversation and tool-call handling both agents share.
- **No Python in the guest.** The specification lists Python among the guest
  tools; this project's standing constraint is that the guest image stays
  lean and Python-free. The shipped RV64 image provides a POSIX shell,
  coreutils, `find`, `grep`, `sed`, `awk`, `make` and a C compiler (TCC).
  `git` and `curl` are not in it either.
- **Host resource limits are not applied by the harness.** It bounds steps,
  wall-clock time, per-command time and output size. CPU, memory, disk and
  process caps are the supervisor's job, and claiming them here would be
  claiming containment this program does not provide.
