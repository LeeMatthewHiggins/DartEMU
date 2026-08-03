# dart_emu

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

A RISC-V system emulator written in pure Dart. It boots Linux, runs
everywhere Dart runs — including a browser tab — and treats a whole machine
as something your program can hold, start, snapshot and throw away.

Ported from [TinyEMU](https://bellard.org/tinyemu/) by Fabrice Bellard.

```dart
final sandbox = AgentSandbox(SandboxConfig(
  kernelData: kernel, rootfsData: rootfs, biosData: bios,
));

await sandbox.boot();                          // ~0.5 s to a shell
final r = await sandbox.exec('uname -m');      // riscv64
await sandbox.dispose();                       // and it is gone
```

## Why this exists

Most sandboxing borrows a boundary from the host: a container, a `chroot`, a
seccomp filter, a user account. Each is a fence drawn around code that is
still running on your CPU, and each fails the same way — one kernel bug and
the fence is on the wrong side.

An emulated machine is different in kind. The guest never executes a host
instruction. There is no syscall to escape through, because there is no
shared kernel to make one to. Containment is a consequence of emulation
rather than a set of rules that have to hold.

That has a cost — you are paying an interpreter — and it buys three things
worth having:

- **It runs anywhere.** Same code on a server, a laptop, a phone and a
  browser tab. No native binary, no VM extensions, no privileged daemon, no
  Docker.
- **A machine is a value.** Boot it, snapshot it in 29 ms, restore that
  snapshot into as many independent clones as you like, discard them.
- **You control what exists.** The guest reaches exactly the network,
  files and devices you hand it. Not what a policy permits — what exists.

Useful for running model-authored or untrusted code, for teaching and
demonstrating systems in a browser, for reproducible test environments, and
for embedding a real Linux machine in an application.

## What it does

- **RV64IMAFDC and RV32IMAFDC**, all privilege levels (M/S/U), SV39 and SV32
  virtual memory with hardware page-table walking
- **Boots current Linux** — 6.12 builds are provided — either behind BBL or
  with the emulator answering SBI v2.0 calls itself as machine-mode firmware
- **VirtIO** console, block, network and 9P, plus CLINT, PLIC and HTIF
- **User-mode networking** with ARP, DHCP, DNS, ICMP, TCP and UDP, and a
  swappable backend that decides what the guest can reach
- **Runs in a browser** — RV32 on any web backend, RV64 under WasmGC
- **`AgentSandbox`** for running commands under wall-clock and instruction
  budgets, with file exchange and snapshot/restore
- **[AgentOS](agentos/)** — an image whose console *is* an agent, with no
  shell behind it and no credential in it
- **YAML configuration** and `.zip` bundles that carry a whole machine

## Try it

```sh
# In a browser, right now — nothing to install
open https://dartemu-3ef91.web.app

# Or locally
git clone https://github.com/LeeMatthewHiggins/DartEMU
cd DartEMU
dart pub get
dart run bin/dart_emu.dart run --config data/alpine_vm.yaml
```

The RV64 demo image ships a C compiler, so `?boot=64` gives you a browser
tab that compiles and runs C.

## Install

```sh
dart pub add dart_emu                      # as a library
dart pub global activate dart_emu          # as a CLI
```

## How it fits together

```
your program
     │
     ├── Emulator ──────────── lifecycle, console streams, stepFor()
     └── AgentSandbox ──────── boot, exec under budgets, snapshot
              │
        RiscVMachine ───────── CPU ▸ MMU ▸ memory map ▸ devices
              │
     ┌────────┼────────┬──────────────┐
  BlockDevice │  NinePBackend    NetBackend        ← the seams
   memory     │   directory       real sockets
   file       │   in-memory       browser proxy
              │   browser folder
        CharacterDevice
```

Everything platform-specific sits behind one of those interfaces, which is
why the same core runs on a server and in a browser tab. Three entry points
keep the split honest:

| Import | Use when |
| --- | --- |
| `package:dart_emu/dart_emu.dart` | anywhere, including web |
| `package:dart_emu/dart_emu_io.dart` | server, desktop, CLI |
| `package:dart_emu/dart_emu_web.dart` | browser |

The core has no `dart:io` at all — that is what makes the browser target
possible rather than merely intended.

## Documentation

| Guide | What it covers |
| --- | --- |
| **[Architecture](docs/architecture.md)** | Layers, every interface, where the boundaries are, how a request leaves a browser guest |
| **[Agents](docs/agents.md)** | `AgentSandbox` and AgentOS, budgets, snapshots, the credential design |
| **[Networking](docs/networking.md)** | The TCP/IP stack, backends, the browser proxy, credential injection |
| **[Filesystems](docs/filesystems.md)** | Block devices, 9P shares, backends, containment |
| **[Configuration](docs/configuration.md)** | Every YAML key, bundles, the CLI, building configs in code |
| **[Embedding](docs/embedding.md)** | Flutter, the web target, driving emulation from a `Ticker` |
| **[Building images](docs/images.md)** | Root filesystems, modern kernels, booting without firmware |
| **[Performance](docs/performance.md)** | Throughput, download size, benchmarking, measuring a change |

Also: [`example/`](example/) is a complete Flutter app, and
[`agentos/`](agentos/) is the in-guest agent.

## Performance

Best of 3 on an Apple M3 Pro, Dart 3.12.2 — host-specific, so re-run the
suite rather than trusting the table:

| Workload | RV64 | RV32 |
| --- | --- | --- |
| boot to shell | **0.57 s** | **0.54 s** |
| sha256 of 1 MB | 109 MIPS | 158 MIPS |
| gzip 512 KB | 108 MIPS | 131 MIPS |
| pipes + context switches | 91 MIPS | 113 MIPS |

Restoring a snapshot beats booting by ~37x — 29 ms against 1.1 s. RV32 is
consistently faster than RV64, because 32-bit arithmetic avoids the 64-bit
paths the Dart VM handles less cheaply.

More, including how to measure a change without fooling yourself, in
[Performance](docs/performance.md).

## Contributing

```sh
dart pub get
dart test                                    # unit tests
dart test --run-skipped -t machine           # whole-machine tests
dart test --run-skipped -t sandbox           # boots a guest
dart test -p chrome test/net                 # browser-only paths
dart analyze --fatal-infos --fatal-warnings lib test
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org).
CI runs analysis, formatting, a 50% coverage floor, spell-check, the C
agent's tests and a riscv64 cross-compile.

## Licence

The `dart_emu` source is MIT licensed (see [LICENSE](LICENSE)).

The prebuilt **guest images** in `example/assets/` are a separate matter:
they bundle third-party software under its own terms — notably the Tiny C
Compiler (LGPL-2.1-or-later), BusyBox (GPL-2.0-only), musl libc (MIT), a
Linux kernel (GPL-2.0-only) and JetBrains Mono (OFL-1.1). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sources and pinned
revisions.

If you use this as a library and supply your own guest images, only the MIT
licence applies to you.

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
