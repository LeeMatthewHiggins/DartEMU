# Agents

Running untrusted or model-authored commands inside a disposable machine.

There are two arrangements, and the difference is where the agent sits.

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
| Works with an unmodified image | yes | no — it must be baked in |
| Budgets and kill switch | outside the guest's reach | inside it |
| Model, prompt, loop | yours to write | built in |
| Browser | yes | yes |

Reach for **`AgentSandbox`** when you have a task and want a machine to run
it in — you keep control of the loop, and the limits sit somewhere the guest
cannot touch.

Reach for **AgentOS** when the machine should simply *be* an agent: you hand
someone a console and they talk to it.

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

await sandbox.boot(); // ~0.5 s to a ready shell

final r = await sandbox.exec('echo hello && uname -m');
r.stdout;    // hello\nriscv64
r.exitCode;  // 0
r.succeeded; // true

await sandbox.dispose();
```

`SandboxConfig` also takes `xlen`, `memorySizeMb`, `cmdLine`, `shellPrompt`,
`useBuiltinSbi`, `bootTimeout`, `defaultTimeout`, `defaultMaxInstructions`,
and the shared-folder options below.

Commands run over the guest's serial console, with markers framing each
one's output. The exec loop drives emulation on the current isolate,
yielding to the event loop periodically. **A Flutter UI wanting frame-paced
execution should drive `Emulator` from a `Ticker` instead** — see
[Architecture](architecture.md#the-two-facades).

## Budgets

Two independent limits, because wall-clock and work are different failures.
A command that overruns either is interrupted, and the sandbox stays usable
for the next one:

```dart
final slow = await sandbox.exec('sleep 60',
    timeout: const Duration(seconds: 2));
slow.outcome; // ExecOutcome.timedOut

final busy = await sandbox.exec(r'while true; do :; done',
    maxInstructions: 50000000);
busy.outcome; // ExecOutcome.budgetExceeded
```

Instruction budgets are deterministic in a way wall-clock is not: the same
command costs the same number of instructions on a fast machine and a slow
one, which makes them the better limit for anything you intend to reproduce.

## Snapshot and restore

Booting is fast; restoring is faster by a wide margin — **29 ms against a
1.1 s cold boot (~37x)** in `test/sandbox/snapshot_restore_test.dart`. Boot
once, warm whatever you need, then stamp out clones:

```dart
final origin = AgentSandbox(config);
await origin.boot();
// ... install packages, warm caches ...
final snapshot = origin.snapshot();

final a = AgentSandbox.restore(config, snapshot);
final b = AgentSandbox.restore(config, snapshot);
await a.exec('echo from-clone-a'); // ready immediately
```

A snapshot is a deep copy of the guest's architectural state — registers,
CSRs, all of RAM, the disk, device and timer state. The source may keep
running, and one snapshot can seed any number of clones. Restored guests
roll back anything that happened after the snapshot and keep a coherent
clock, so timers resume rather than jumping.

This is the cheapest way to get a clean machine per task: snapshot after
boot, restore per request, discard.

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

Because it is *inside*, running a command is `fork` and `exec` — none of the
console transport that driving a guest from outside requires exists here. It
is a shell tool, an HTTP client, a chat-completions client and a loop.

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

The machine never holds a key. Requests leave carrying a placeholder that
names the credential they need:

```
guest writes:   Authorization: Bearer ${OPENROUTER_KEY}
host resolves:  Authorization: Bearer sk-real-…
```

This is a property rather than a practice. It is not that care is taken
never to write a key into the image — it is that the image has no field
capable of holding one. A guest taken apart byte by byte yields the string
`${OPENROUTER_KEY}`.

When the host has no credential of that name, the request comes back as a
401 whose message says which one is missing, so the agent reports it instead
of failing blankly. A visitor with no key still gets a working machine.

The substitution happens in [`HttpProxy`](networking.md#credential-injection).

## What neither of them does

Neither filters what may run. There is no command allowlist, no path
restriction, no shell filtering, no confirmation prompt. The machine is the
boundary; asking an agent inside it to be a second one would only make the
real boundary harder to reason about.

What *is* bounded is resource use, and for the machine's sake rather than
the user's:

- Output is capped **as the pipe is drained**, so a command that prints
  without end is killed rather than allowed to exhaust memory. Truncating
  afterwards would already be too late.
- A timeout kills the whole process group, so a backgrounded child cannot
  hold the pipe open and hang the agent.

Both are limits on the guest's own resources. Neither is a security control,
and in AgentOS a sufficiently determined guest can remove its own — which is
exactly the difference the table at the top is describing.
