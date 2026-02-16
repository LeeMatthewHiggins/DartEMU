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
- Stream-based facade for platform-agnostic embedding
- Lifecycle status tracking via `EmulatorStatus`
- YAML-based machine configuration
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
terminal UI that boots RV32 Linux on all platforms including web.

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

## Building a Root Filesystem

A Docker-based image builder is included for creating Alpine Linux root
filesystem images:

```sh
# Minimal image (256MB)
tool/image_builder/build.sh

# Development image with gcc, make, git, nano (512MB)
tool/image_builder/build.sh dev
```

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
  file: rootfs/root-riscv32.bin
```

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
