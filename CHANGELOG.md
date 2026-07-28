# Changelog

## 0.6.0

- Boot a modern Linux kernel with no firmware blob. The emulator now
  implements the Supervisor Binary Interface itself (`lib/src/machine/sbi.dart`,
  SBI v2.0 Base/TIME/IPI/RFENCE/HSM/SRST/DBCN plus the v0.1 legacy console
  calls), so a current kernel can be booted directly instead of through BBL
  or OpenSBI. Enable it with `MachineConfig(useBuiltinSbi: true)` or
  `use_builtin_sbi: true` in a YAML config; a kernel built this way reaches a
  shell in about three seconds. The scope is a single hart, so remote fences
  and inter-processor interrupts reduce to local operations
- A kernel builder: `tool/image_builder/build_kernel.sh [riscv64|riscv32]`
  cross-compiles Linux 6.12 with the devices the emulator presents built in
  rather than modular, and refuses to finish if any of them ended up as a
  module — nothing can be loaded from a root filesystem that is not mounted
  yet. Source and objects are cached per architecture, so changing the
  config fragment costs an incremental rebuild
- CSR and device-tree groundwork for machine-mode firmware: PMP windows,
  `mvendorid`/`marchid`/`mimpid`/`mconfigptr`, `menvcfg`, `mcountinhibit`,
  `mstatush`, `mseccfg` and the trigger registers are implemented rather
  than trapping; `satp.MODE` is now WARL, so selecting an unsupported
  translation scheme leaves the register unchanged instead of throwing; the
  device tree emits a canonical ISA string and gives the HTIF node a `reg`
  range that firmware can find without kernel symbols
- Kernel images are loaded at the offset their Image header declares. The
  load address was previously fixed at 2MB, which is the RV64 default; RV32
  kernels are linked for 4MB and one loaded at 2MB never reached its first
  instruction and produced no output at all
- The counter-enable chain is enforced correctly. A user-mode read of
  `cycle`, `time` or `instret` now requires the bit in both `mcounteren` and
  `scounteren`, on the high halves as well as the low, since supervisor mode
  cannot pass on access that machine mode withheld. Direct boot also grants
  `scounteren`, which Linux never sets itself and firmware is expected to
  provide — without it the vDSO's `rdtime` is an illegal instruction and the
  first process to ask the time is killed
- The SBI console can be read from, not just written to. The legacy
  `console_getchar` and debug-console read calls now take input from the same
  character device the write calls use, so a guest whose only console is this
  interface can be typed at. VirtIO remains the better choice for an
  interactive console: the SBI driver polls a byte per environment call,
  which measured 31s against 1.5s over VirtIO for 128KB written into a guest
- `AgentSandbox.boot()` now fails when the guest reaches a prompt but its
  shell never responds, instead of returning normally and surfacing the
  problem as an unrelated error from the next `exec`
- `SandboxConfig.biosData` is optional, paired with a new `useBuiltinSbi`
  flag and an assertion that exactly one Supervisor Binary Interface is
  configured — firmware serves SBI calls from the trap path, so installing
  both would leave the emulator shadowing the firmware
- A TCC `tests2` conformance suite runs the upstream C test cases inside the
  guest as an emulator correctness check
- The web demo no longer registers a service worker
- VirtIO-9P shared filesystem: a new `Virtio9pDevice` speaks 9P2000.u to
  the guest's `v9fs` client, exposing a host folder (or an in-memory tree)
  as a mountable share. Add shares via `MachineConfig.sharedFolders`
  (`NinePShare(tag, backend)`); back them with
  `createDirectoryNinePBackend(path)` for host passthrough or
  `MemoryNinePBackend` for a web-safe in-memory tree
- `AgentSandbox` gains `SandboxConfig.sharedFolder`: the share is mounted
  automatically at boot (`/mnt/shared` by default), and host-side reads
  and writes appear in the guest live with no console round-trip —
  replacing the base64-over-console path for bulk file exchange. Call
  `mountSharedFolder()` to remount after `AgentSandbox.restore`
- The advertised VirtIO virtqueue size grew from 16 to 128 descriptors so
  a 9P client can fit a full `msize` request in one scatter-gather list
- Hardened against untrusted guests: the directory backend now rejects
  symlink traversal (final or intermediate) that escapes the shared root,
  and the 9P reader is fully bounds-checked so malformed or truncated
  frames return `Rerror` instead of crashing the host emulator
- Web File System Access: `package:dart_emu/dart_emu_web.dart` adds
  `pickDirectoryShare()`, which prompts the browser's directory picker and
  loads the chosen folder into a 9P share (the tree is read once up front,
  since the 9P device is synchronous). The directory is opened read-write
  and a `WriteBackNinePBackend` mirrors guest writes, creates, removes and
  truncations back to the folder asynchronously. The example demo gains a
  "Mount a folder & boot" button that shares a local folder into the guest
  at `/mnt/host`
- A picked web share can be refreshed: `PickedShare.refresh` (and a
  "Reload folder" control in the demo) re-reads the chosen directory and
  merges host-side additions and edits into the guest's view — additive
  and host-wins, so unsynced guest files are never clobbered. The re-sync
  is mtime-diffed, re-reading only files whose `lastModified` changed, and
  the demo polls it in the background so host changes reach the guest
  automatically. This softens the one-shot snapshot for host→guest changes
  without a live-sync rewrite

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
