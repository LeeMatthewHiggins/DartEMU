# Agents

Running untrusted or model-authored commands inside a disposable machine.

The agent can run in the host process or inside the guest.

- [Choosing between them](#choosing-between-them)
- [AgentSandbox — the agent outside](#agentsandbox--the-agent-outside)
- [Budgets](#budgets)
- [Snapshot and restore](#snapshot-and-restore)
- [Files](#files)
- [AgentOS — the agent inside](#agentos--the-agent-inside)
- [The credential it does not have](#the-credential-it-does-not-have)
- [What neither of them does](#what-neither-of-them-does)

## Choosing between them

|  | `AgentSandbox` | AgentOS |
| --- | --- | --- |
| Where the agent runs | your process | inside the guest |
| Language | Dart | C, compiled into the image |
| Guest requirement | interactive shell with a known prompt | agent installed in the image |
| Budgets and kill switch | outside the guest's reach | inside it |
| Model, prompt, loop | yours to write | built in |
| Browser | yes | yes |

Use `AgentSandbox` to control commands and budgets from your application.
Use AgentOS for an agent that interacts through the guest console.

## AgentSandbox — the agent outside

It boots a fresh guest from in-memory images and runs shell commands with
captured output, exit codes, and per-command budgets. The guest is
air-gapped unless you give it a network.

```dart
import 'package:dart_emu/dart_emu.dart';

final sandbox = AgentSandbox(
  SandboxConfig(
    biosData: biosBytes,
    kernelData: kernelBytes,
    rootfsData: rootfsBytes, // booted from a fresh copy each time
    // ethDevices defaults to [] — air-gapped.
  ),
);

await sandbox.boot(); // waits for the configured shell prompt

final r = await sandbox.exec('echo hello && uname -m');
r.stdout;    // hello\nriscv64
r.exitCode;  // 0
r.succeeded; // true

await sandbox.dispose();
```

`SandboxConfig` also takes `xlen`, `memorySizeMb`, `cmdLine`, `shellPrompt`,
`useBuiltinSbi`, `bootTimeout`, `defaultTimeout`, `defaultMaxInstructions`,
and the shared-folder options below.

Provide matching firmware, kernel and rootfs bytes for the selected
architecture. The default prompt is `~ # `; configure `shellPrompt` for
other images. Login prompts and interactive authentication are not handled
automatically.

Commands run over the guest's serial console, with markers framing each
one's output. `stdout` combines stdout and stderr. The exec loop drives
emulation on the current isolate, yielding to the event loop periodically. **A Flutter UI wanting frame-paced
execution should drive `Emulator` from a `Ticker` instead** — see
[Architecture](architecture.md#the-two-facades).

## Budgets

Two independent limits, because wall-clock and work are different failures.
When a command overruns either, the sandbox sends Ctrl+C and tries to
recover the shell. Check `sandbox.ready` before reusing it: failed recovery
marks it not ready, and recovery may take up to another 10 seconds:

```dart
final slow = await sandbox.exec('sleep 60',
    timeout: const Duration(seconds: 2));
slow.outcome; // ExecOutcome.timedOut

final busy = await sandbox.exec(r'while true; do :; done',
    maxInstructions: 50000000);
busy.outcome; // ExecOutcome.budgetExceeded
```

Instruction budgets count guest instructions, while wall-clock budgets
measure host time. Checks happen between execution batches, so limits can
overshoot by a batch. Scheduling, guest timers and I/O can change instruction
counts between runs; they are not a guarantee of deterministic execution.

## Snapshot and restore

A recorded run of `test/sandbox/snapshot_restore_test.dart` measured
**29 ms restore against a 1.1 s cold boot (~37x)**. These timings depend on
the host and guest image. Boot
once, warm whatever you need, then stamp out clones:

```dart
final origin = AgentSandbox(config);
await origin.boot();
// ... install packages, warm caches ...
final snapshot = origin.snapshot();

final a = AgentSandbox.restore(config, snapshot);
final b = AgentSandbox.restore(config, snapshot);
await a.exec('echo from-clone-a'); // no reboot required
await a.dispose();
await b.dispose();
await origin.dispose();
```

A snapshot is a deep copy of the guest's architectural state — registers,
CSRs, all of RAM, the disk, device and timer state. The source may keep
running, and one snapshot can seed any number of clones. Restored guests
roll back anything that happened after the snapshot and keep a coherent
clock, so timers resume rather than jumping.

Take snapshots while the shell is idle, and restore with a matching
configuration. Network sessions and shared-folder contents are not included.
Use separate backends for independent clones, and call
`await clone.mountSharedFolder()` to re-establish a configured 9P share.

For repeated tasks, snapshot after boot, restore per request, and dispose
each clone after use.

## Files

File exchange is base64 over the console, which works on every platform
including the browser:

```dart
await sandbox.writeText('/tmp/main.c', cSource);
final out = await sandbox.exec('cc /tmp/main.c -o /tmp/a.out && /tmp/a.out');
final binary = await sandbox.readFile('/tmp/a.out'); // a real ELF
```

The bundled RV64 image ships TCC as `cc`, so a guest can compile and run C.

For anything larger than a file or two, mount a share instead — 9P moves
bytes far more cheaply than base64 over a serial line. See
[Filesystems](filesystems.md).

## AgentOS — the agent inside

[`agentos/`](../agentos) is a small C program that replaces the guest's
console getty:

```
hvc0::respawn:/usr/local/bin/agentos-console
```

Talking to the machine means talking to the agent, and there is no shell
behind it. `init` respawns the agent, so a restart cannot fall through to
one either.

AgentOS runs commands through `fork` and `exec` inside the guest. It
includes a shell tool, HTTP client, chat-completions client and agent loop.

Build it, put it in an image, and boot:

```sh
agentos/build_guest.sh                          # static riscv64, ~600 KB
tool/image_builder/build.sh riscv64 agentos
dart run bin/dart_emu.dart run --config data/agentos_vm.yaml
```

Configuration comes from flags or environment variables — `AGENTOS_MODEL`,
`AGENTOS_HOST`, `AGENTOS_MAX_STEPS`, `AGENTOS_MAX_OUTPUT`,
`AGENTOS_TIMEOUT_MS` and friends; run `agentos --help` for the list. The web
demo passes the model on the kernel command line (`agentos.model=…`), which
is the one channel a page can set per boot without rebuilding the image.

## The credential it does not have

The supplied AgentOS image contains no API key. Requests leave carrying a
placeholder that names the credential configured on the host:

```
guest writes:   Authorization: Bearer ${OPENROUTER_KEY}
host resolves:  Authorization: Bearer sk-real-…
```

The host's configured proxy header resolves `${OPENROUTER_KEY}` before
sending the upstream request. The key is kept out of the supplied image and
console configuration. This does not prevent guest programs from storing
secrets supplied through other channels.

When the host has no credential of that name, the request comes back as a
401 whose message says which one is missing, so the agent reports it instead
of failing blankly. A visitor with no key still gets a working machine.

The substitution happens in [`HttpProxy`](networking.md#credential-injection).

## What neither of them does

Neither filters guest commands, restricts guest paths, or asks for
confirmation. Host access depends on the configured devices and backends.

AgentOS applies these limits inside the guest:

- Output is capped **as the pipe is drained**, so a command that prints
  without end is killed rather than allowed to exhaust memory. Truncating
  afterwards would already be too late.
- A timeout kills the whole process group, so a backgrounded child cannot
  hold the pipe open and hang the agent.

A guest with root access can change those AgentOS limits. `AgentSandbox`
instead checks time and instruction budgets on the host, but currently has
no output-size cap: its console capture grows in host memory. Its serial
markers and reported exit codes also assume a cooperating guest shell.
Use a separate host process and host resource limits when those guarantees
are required.
