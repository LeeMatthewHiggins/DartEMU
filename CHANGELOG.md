# Changelog

## 0.1.0

- RISC-V 64-bit system emulator ported from TinyEMU
- Stream-based `Emulator` facade for embedding in CLI and Flutter applications
- `EmulatorStatus` lifecycle tracking (idle, starting, running, stopped, error)
- YAML-based machine configuration via `ConfigLoader`
- Support for both file-path and in-memory BIOS/kernel loading
- VirtIO console, block device, and network device support
- CLI with `dart_emu run` command
- Alpine Linux rootfs image builder (Docker-based)
