/// A RISC-V system emulator (RV64 and RV32) ported from TinyEMU.
///
/// Use `Xlen.rv32` for web-compatible 32-bit mode or `Xlen.rv64` for
/// 64-bit mode. This library is platform-independent and does not depend
/// on `dart:io`. For file-based configuration loading and block devices,
/// use `package:dart_emu/dart_emu_io.dart` instead.
library;

export 'src/cpu/cpu_executor.dart';
export 'src/cpu/cpu_state.dart';
export 'src/device/block_device.dart';
export 'src/device/character_device.dart';
export 'src/device/ethernet_device.dart';
export 'src/device/irq_signal.dart';
export 'src/device/memory_block_device.dart';
export 'src/device/virtio/ninep/ninep_fs.dart';
export 'src/device/virtio/ninep/ninep_memory_backend.dart';
export 'src/device/virtio/virtio_9p.dart';
export 'src/emulator/emulator.dart';
export 'src/emulator/emulator_status.dart';
export 'src/machine/clint.dart';
export 'src/machine/htif.dart';
export 'src/machine/machine_config.dart';
export 'src/machine/machine_snapshot.dart';
export 'src/machine/memory_map_layout.dart';
export 'src/machine/phys_memory_map.dart';
export 'src/machine/phys_memory_range.dart';
export 'src/machine/plic.dart';
export 'src/machine/riscv_machine.dart';
export 'src/net/user_net_device.dart';
export 'src/sandbox/agent_sandbox.dart';
export 'src/sandbox/exec_result.dart';
export 'src/sandbox/sandbox_config.dart';
export 'src/sandbox/sandbox_console.dart';
export 'src/sandbox/sandbox_files.dart';
