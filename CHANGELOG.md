# Changelog

## 0.2.0

- RV32IMAFDC support via `Xlen.rv32` configuration
- Web platform compatibility for RV32 (no 64-bit integer dependency)
- SV32 page table walking for RV32 virtual memory
- `ByteData`-backed FP register file for web-safe 64-bit storage
- `time` and `timeh` CSR support for RV32 timer access
- Flutter example app with terminal UI (boots Linux on all platforms)
- Conditional 64-bit constants via `dart.library.js_interop` platform split

## 0.1.0

- RISC-V 64-bit system emulator ported from TinyEMU
- Stream-based `Emulator` facade for embedding in CLI and Flutter applications
- `EmulatorStatus` lifecycle tracking (idle, starting, running, stopped, error)
- YAML-based machine configuration via `ConfigLoader`
- Support for both file-path and in-memory BIOS/kernel loading
- VirtIO console, block device, and network device support
- CLI with `dart_emu run` command
- Alpine Linux rootfs image builder (Docker-based)
