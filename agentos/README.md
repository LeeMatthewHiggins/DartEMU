# AgentOS

An agent that runs *inside* the emulated machine, as its only console.

Driving a guest from outside means opening a shell over the serial console
and shipping commands in as newline-delimited JSON — machinery that exists
only because the agent and the machine are separated by a console. AgentOS
removes the separation: the agent is a program in the guest, so running a
command is `fork` and `exec`, and the transport disappears with it.

What is left is small — a shell tool, a plain-HTTP client, a
chat-completions client and a loop — and it is the whole program.

The outside arrangement is still available in Dart, through
[`AgentSandbox`](../lib/src/sandbox/agent_sandbox.dart), which boots a guest
and runs commands against it under wall-clock and instruction budgets. Reach
for that when the image cannot be modified or the budgets must sit somewhere
the guest cannot reach; reach for this when the machine should simply *be*
an agent.

## The credential it does not have

The machine never holds a key. It sends a placeholder in the `Authorization`
header — `Bearer ${OPENROUTER_KEY}` by default — to a name that resolves to
its host. The host recognises the name, substitutes the real value, and
forwards the request over TLS.

The consequence is worth stating plainly: a machine that has been completely
compromised yields the *name* of a credential. There is no field in this
program capable of holding one, which is a stronger claim than any amount of
care about where a key is stored.

When the host has no credential for that name, the request comes back as a
401 whose message says which one is missing. The agent reads it and reports
it, which is why a keyless visitor still gets a machine that runs.

## What it does not do

Nothing here filters what may run. There is no command allowlist, no path
restriction, no shell filtering, no permission prompt. The machine is the
boundary; the agent inside it is not asked to be a second one, and pretending
otherwise would only make the real boundary harder to reason about.

Output and time are bounded, but for the machine's sake rather than the
user's: output is capped as the pipe is drained, so a command that prints
without end is killed rather than allowed to exhaust memory, and a timeout
takes the whole process group so a backgrounded child cannot hold the pipe
open.

## Building

```sh
make          # host build, for running and testing at native speed
make test     # unit tests
make guest    # static riscv64 binary for the image
```

`make guest` needs `riscv64-linux-gnu-gcc` and `libc6-dev-riscv64-cross`.
`./build_guest.sh` supplies both in a container, so a host with Docker needs
nothing else installed.

The binary is static because the guest is Alpine — its libc is musl, and a
dynamically linked glibc binary would not start — and because it should keep
working after the model has rearranged the machine around it.

## Putting it in a machine

```sh
tool/image_builder/build.sh riscv64 agentos
dart run bin/dart_emu.dart run --config data/agentos_vm.yaml
```

The image replaces the console getty with the agent, so talking to the
machine means talking to the agent. There is no shell to drop into.

Booted from the CLI there is no proxy listening, so the first request comes
back saying nothing is proxying for this machine. The web demo in
[`example/`](../example) supplies one.

## Configuration

Every option is a flag or an environment variable; run `agentos --help` for
the list. The defaults assume the emulator's own gateway at `10.0.2.2` and an
upstream named `llm.local`.
