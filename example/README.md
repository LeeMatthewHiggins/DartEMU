# DartEMU Flutter Example

A Flutter application that boots a RISC-V 32-bit Linux system using the
`dart_emu` package. Runs on all Flutter platforms including web.

## Running

```sh
flutter run
```

For web:

```sh
flutter build web --release
```

## Boot Images

The example loads RV32 boot images from `assets/`:

- `bbl32.bin` — OpenSBI firmware
- `kernel-riscv32.bin` — Linux kernel
- `root-riscv32.bin` — Root filesystem (ext2)

These must be placed in the `assets/` directory before building.

## Architecture

- `EmulatorController` — Loads assets, creates `MachineConfig` with
  `Xlen.rv32`, and manages the `Emulator` lifecycle
- `TerminalScreen` — Displays emulator output in a terminal widget and
  forwards keyboard input to the guest OS
