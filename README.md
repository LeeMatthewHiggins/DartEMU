# dart_emu

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

A RISC-V system emulator for Dart, ported from
[TinyEMU](https://bellard.org/tinyemu/). Boots Linux with stream-based I/O
for embedding in CLI, Flutter, and web applications.

## Features

- RV64IMAFDC and RV32IMAFDC instruction sets with full privilege levels (Machine, Supervisor, User)
- SV39 (RV64) and SV32 (RV32) virtual memory with hardware page table walking
- RV32 runs on all Dart platforms including web (no 64-bit integer dependency)
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
flutter build web --release
```

To skip the config picker and boot the demo directly, add `?boot=32` to the
URL.

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

**RV64 (Alpine Linux):**

```sh
tool/image_builder/build.sh riscv64           # minimal (256MB)
tool/image_builder/build.sh riscv64 dev       # with gcc, make, git, nano (512MB)
```

**RV32 (Buildroot + musl):**

```sh
tool/image_builder/build_buildroot.sh         # minimal (256MB)
tool/image_builder/build_buildroot.sh dev     # with tcc, make, git, nano (512MB)
```

The RV32 dev image includes TCC (Tiny C Compiler) instead of GCC for
practical compile times inside the emulator.

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
