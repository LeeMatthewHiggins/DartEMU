# Changelog

## 0.5.0

- Machine snapshot/restore: `RiscVMachine.snapshot()` captures full
  architectural state (CPU registers and CSRs, RAM, block devices,
  timer, interrupt controller, and VirtIO device state) into a
  `MachineSnapshot`; `RiscVMachine.restore(config, snapshot)` rebuilds
  an equivalent machine with derived caches rebuilt on demand
- `AgentSandbox.snapshot()` and `AgentSandbox.restore()`: boot once,
  snapshot the warm VM, then spin up independent clones in ~tens of
  milliseconds (~37x faster than a cold boot) instead of re-booting;
  restored guests roll back changes and keep a coherent clock
- The bundled RV64 guest image now ships a C compiler (TCC), so guests
  can compile and run C; a new builder (`tool/image_builder/build_tcc.sh`)
  cross-builds a lean ~23MB image
- The example terminal shows a branded startup banner while the guest
  boots
- `THIRD_PARTY_NOTICES.md` documents the licences of software bundled in
  the guest images (TCC, BusyBox, musl, the Linux kernel), and the TCC
  build is pinned to an exact upstream revision
- README gains a Performance section with measured throughput and web
  download sizes

## 0.4.0

- `AgentSandbox`: high-level facade for running untrusted or
  agent-authored commands in a disposable Linux guest — `boot()`,
  `exec()` with captured stdout, exit codes, and per-command
  wall-clock and instruction budgets, and file exchange
  (`writeFile`/`readFile`/`writeText`/`readText`) over the console
- Air-gapped by default; opt into a `UserNetDevice` with a filtering
  `NetBackend` for a controlled network allow-list
- Timed-out or over-budget commands are interrupted and the sandbox
  resyncs, so it stays reusable
- Predecoded instruction cache for RV64 and RV32: decode each code page
  once into micro-ops, cutting per-instruction fetch and dispatch
  (~1.7x faster on RV64, ~1.9x on RV32 across the workload suite)
- Physically-keyed decode cache with write-snooped invalidation, so
  self-modifying guests stay correct without relying on `fence.i`
- Faster instruction fetch: probe the code TLB before walking page
  tables on a miss
- WebAssembly (WasmGC) web build via `flutter build web --wasm`,
  measurably faster than the JavaScript backend with automatic
  fallback on browsers without WasmGC
- RV64 now runs on the web under WasmGC (native 64-bit integers);
  fixed 64-bit constant stubs being selected for the wasm backend
- Guest-workload benchmark suite with per-subsystem workloads,
  noise-aware baseline comparison, a VM-service CPU profiler, and
  micro-op pair-frequency instrumentation (`tool/bench/`)

## 0.3.0

- User-mode networking with DNS, DHCP, TCP/UDP proxy via `UserNetDevice`
- Networking enabled by default on all VM images and demo boot
- Config file picker with drag-and-drop and ZIP bundle loading
- RV32 Buildroot image builder with TCC (Tiny C Compiler) for dev images
- `?boot=32` / `?boot=64` URL parameter to skip config picker on web
- Firebase Hosting deployment with GitHub Actions CI/CD
- Auto-DHCP in guest init scripts for immediate network on boot

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
