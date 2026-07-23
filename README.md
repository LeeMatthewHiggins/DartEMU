# dart_emu

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

A RISC-V system emulator for Dart, ported from
[TinyEMU](https://bellard.org/tinyemu/). Boots Linux with stream-based I/O
for embedding in CLI, Flutter, and web applications.

## Features

- RV64IMAFDC and RV32IMAFDC instruction sets with full privilege levels (Machine, Supervisor, User)
- SV39 (RV64) and SV32 (RV32) virtual memory with hardware page table walking
- Predecoded instruction cache for fast interpretation (~1.7x on RV64, ~1.9x on RV32)
- Runs on every Dart platform including the browser — RV32 on any web backend, RV64 under WebAssembly (WasmGC)
- `AgentSandbox` facade: boot a disposable guest and run commands with captured output, exit codes, wall-clock/instruction budgets, and file exchange
- Bundled RV64 image ships a C compiler (TCC), so guests can compile and run C
- VirtIO console, block device, and network device
- User-mode networking with DNS, DHCP, and TCP/UDP proxy
- Stream-based facade for platform-agnostic embedding
- Lifecycle status tracking via `EmulatorStatus`
- YAML-based machine configuration with ZIP bundle support
- Supports both file-path and in-memory BIOS/kernel loading

## Library Usage

```dart
import 'package:dart_emu/dart_emu.dart';

final config = MachineConfig(
  xlen: Xlen.rv64,        // or Xlen.rv32 for 32-bit (web-compatible)
  biosData: biosBytes,     // Uint8List
  kernelData: kernelBytes, // Uint8List
  cmdLine: 'console=hvc0 root=/dev/vda rw',
  blockDevices: [MemoryBlockDevice.fromData(rootfsBytes)],
  ethDevices: [UserNetDevice()], // user-mode networking
);

final emulator = Emulator(config);

// Listen to console output
emulator.output.listen((bytes) => handleOutput(bytes));

// Track lifecycle
emulator.status.listen((status) => print('Status: $status'));

// Send console input
emulator.sendInput(inputBytes);

// Run (completes when guest shuts down or stop() is called)
await emulator.start();

// Clean up
await emulator.dispose();
```

## Agent Sandbox

`AgentSandbox` is a higher-level facade for running untrusted or
agent-authored commands in a disposable Linux VM. It boots a fresh
guest from in-memory images, runs shell commands with captured output,
exit codes, and per-command wall-clock and instruction budgets, and
exchanges files with the guest. The guest never executes a host
instruction and is air-gapped by default, so the whole VM is a
throwaway isolation boundary that works identically on server,
desktop, mobile, and web.

```dart
import 'package:dart_emu/dart_emu.dart';

final sandbox = AgentSandbox(
  SandboxConfig(
    biosData: biosBytes,     // Uint8List
    kernelData: kernelBytes,
    rootfsData: rootfsBytes, // booted from a fresh copy each time
    // ethDevices defaults to [] — air-gapped. Pass a UserNetDevice
    // with a filtering NetBackend for a controlled allow-list.
  ),
);

await sandbox.boot(); // ~0.5s to a ready shell

// Run a command: captured stdout, exit code, cost.
final r = await sandbox.exec('echo hello && uname -m');
print(r.stdout);    // hello\nriscv64
print(r.exitCode);  // 0
print(r.succeeded); // true

// Budgets: a command that overruns is interrupted and the sandbox
// stays usable for the next exec.
final slow = await sandbox.exec('sleep 60', timeout: Duration(seconds: 2));
print(slow.outcome); // ExecOutcome.timedOut

final busy = await sandbox.exec(
  r'while true; do :; done',
  maxInstructions: 50000000,
);
print(busy.outcome); // ExecOutcome.budgetExceeded

// File exchange (base64 over the console — works everywhere). The
// bundled RV64 image includes a C compiler (TCC) as `cc`.
await sandbox.writeText('/tmp/main.c', cSource);
final out = await sandbox.exec('cc /tmp/main.c -o /tmp/a.out && /tmp/a.out');
final artifact = await sandbox.readFile('/tmp/a.out'); // a real ELF

await sandbox.dispose();
```

The exec loop drives emulation on the current isolate, yielding to the
event loop periodically. A Flutter UI that needs frame-paced execution
should drive the lower-level `Emulator` from a `Ticker` instead. See
`test/sandbox/agent_sandbox_test.dart` for a full working example
(run with `dart test --run-skipped -t sandbox`).

## Flutter / Web Integration

Use `Xlen.rv32` for web targets. RV32 avoids 64-bit integer operations that
are unsupported in JavaScript.

```dart
final config = MachineConfig(
  xlen: Xlen.rv32,
  biosData: biosBytes,
  kernelData: kernelBytes,
  cmdLine: 'console=hvc0 root=/dev/vda rw',
  blockDevices: [MemoryBlockDevice.fromData(rootfsBytes)],
  ethDevices: [UserNetDevice()],
);

final emulator = Emulator(config);

emulator.output.listen((bytes) {
  terminalController.write(bytes);
});

emulator.status.listen((status) {
  setState(() => _status = status);
});

emulator.start(); // runs in the event loop
```

See the [example](example/) directory for a complete Flutter app with a
terminal UI, config picker, and ZIP bundle loading.

## CLI Usage

Install globally:

```sh
dart pub global activate dart_emu
```

Run with a configuration file:

```sh
dart_emu run --config data/alpine_vm.yaml
```

Run with individual options:

```sh
dart_emu run --bios bbl64.bin --kernel kernel-riscv64.bin --drive rootfs.bin
```

## Web Platform

The RV32 configuration is fully web-compatible. It uses `Uint32List` for
integer registers and `ByteData`-backed storage for FP registers, avoiding
all 64-bit integer APIs (`Int64List`, `getUint64`, `setUint64`) that are
unsupported in JavaScript.

Build the example for web:

```sh
cd example
flutter build web --wasm --release
```

The `--wasm` flag compiles to WebAssembly (WasmGC), which runs the
emulator measurably faster than the JavaScript backend (~1.4-1.7x on
guest workloads and kernel boot); browsers without WasmGC support fall
back to the bundled JavaScript build automatically.

To skip the config picker and boot the demo directly, add `?boot=32` or
`?boot=64` to the URL. RV64 needs the WasmGC build (native 64-bit
integers) and is the variant whose image ships a C compiler, so
`?boot=64` gives you a browser tab that can compile and run C.

## Benchmarking

A guest-workload benchmark measures emulation throughput (wall time,
retired instructions, and MIPS) for boot plus workloads that each
stress a distinct emulator subsystem: exec round-trip latency, process
creation, shell CPU, pipes and context switches, soft-float, sorting,
compression, hashing, kernel memcpy, and VirtIO block I/O. It boots
from an in-memory copy of the rootfs, so the asset images are never
modified.

```sh
dart tool/bench/bench.dart                    # RV32, 3 runs, full suite
dart tool/bench/bench.dart --xlen rv64        # RV64
dart tool/bench/bench.dart --quick            # 1 run, reduced set
dart tool/bench/bench.dart --list             # show available workloads
dart tool/bench/bench.dart --workloads sh_loop_10k,disk_read_4m
```

Results are aggregated across runs as best/median/mean with a
coefficient-of-variation column; `best` is the least noisy. Each
workload's guest exit status is checked, so a failing command is
reported rather than silently timed.

To measure a performance change, record a baseline, make the change,
and compare:

```sh
dart tool/bench/bench.dart --json > tool/bench/baselines/before.json
# ... make changes ...
dart tool/bench/bench.dart --json > tool/bench/baselines/after.json
dart tool/bench/compare.dart tool/bench/baselines/{before,after}.json
```

The compare tool marks a phase FASTER/SLOWER only when the delta
exceeds the measured noise of both baselines, and supports
`--fail-on-regress <pct>` for CI gates. Baselines are host-specific
and gitignored.

## Building Root Filesystems

Docker-based image builders are included for creating rootfs images.

**RV64 with a C compiler (Alpine + TCC)** — this is the image bundled as
`example/assets/root-riscv64.bin`:

```sh
tool/image_builder/build_tcc.sh               # ~23MB, includes cc (TCC)
```

TCC is a few hundred KB and links binaries itself, so the image stays
small enough to ship as a demo/test asset. The build cross-compiles a
statically-linked riscv64 TCC and pairs it with `musl-dev` headers and
crt objects, so `cc hello.c -o hello` works in the guest. (`tcc -static`
is unavailable — musl's 28MB `libc.a` is dropped to keep the image
small.)

**RV64 (Alpine Linux):**

```sh
tool/image_builder/build.sh riscv64           # minimal (256MB)
tool/image_builder/build.sh riscv64 dev       # with gcc, make, git, nano (512MB)
```

**RV32 (Buildroot + musl):**

```sh
tool/image_builder/build_buildroot.sh         # minimal (256MB)
tool/image_builder/build_buildroot.sh dev     # native gcc toolchain (512MB)
```

The `dev` variants build a full native GCC (a Canadian cross for RV32),
which takes 15-30 minutes and produces a large image. TCC is only
available for RV64 — upstream TCC has no riscv32 backend.

Images are packaged as ZIP bundles in `data/` that the Flutter app can load
via drag-and-drop or file picker.

## Configuration

Machine configuration uses YAML files:

```yaml
version: 1
machine: riscv64
memory_size: 256
bios: bbl64.bin
kernel: kernel-riscv64.bin
cmdline: "console=hvc0 root=/dev/vda rw"
drive0:
  file: rootfs/alpine-riscv64-rootfs.bin
eth0:
  driver: user
```

For RV32:

```yaml
version: 1
machine: riscv32
memory_size: 256
bios: bbl32.bin
kernel: kernel-riscv32.bin
cmdline: "console=hvc0 root=/dev/vda rw"
drive0:
  file: rootfs/alpine-riscv32-rootfs.bin
eth0:
  driver: user
```

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
