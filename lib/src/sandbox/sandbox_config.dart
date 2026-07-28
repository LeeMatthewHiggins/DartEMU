import 'dart:typed_data';

import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';

/// Configuration for an `AgentSandbox`.
///
/// Holds the guest images in memory so a sandbox is platform-independent
/// (no `dart:io`) and each session boots from a pristine copy — the
/// backing images are never mutated.
class SandboxConfig {
  SandboxConfig({
    required this.kernelData,
    required this.rootfsData,
    this.biosData,
    this.useBuiltinSbi = false,
    this.xlen = Xlen.rv64,
    this.memorySizeMb = 128,
    this.cmdLine = 'console=hvc0 root=/dev/vda rw',
    this.shellPrompt = '~ # ',
    this.ethDevices = const [],
    this.sharedFolder,
    this.sharedMountPoint = '/mnt/shared',
    this.autoMountShared = true,
    this.bootTimeout = const Duration(seconds: 30),
    this.defaultTimeout = const Duration(seconds: 30),
    this.defaultMaxInstructions,
  }) : assert(
         (biosData != null) != useBuiltinSbi,
         'Provide exactly one Supervisor Binary Interface: firmware through '
         'biosData, or the emulator itself through useBuiltinSbi. Firmware '
         'services SBI calls from the trap path, so installing both would '
         'leave the emulator shadowing the firmware.',
       );

  /// Bootloader (BBL/OpenSBI) image.
  ///
  /// Null when [useBuiltinSbi] is set and the emulator supplies the
  /// Supervisor Binary Interface itself, which is how a modern kernel boots.
  final Uint8List? biosData;

  /// Whether the emulator acts as machine-mode firmware.
  ///
  /// Set this instead of [biosData] to boot a kernel with no firmware blob.
  /// Such a kernel needs `earlycon=sbi` on the command line: it has no HTIF
  /// console driver, so without it an early failure produces no output.
  final bool useBuiltinSbi;

  /// Linux kernel image.
  final Uint8List kernelData;

  /// Root filesystem image, mounted read-write from a fresh copy.
  final Uint8List rootfsData;

  /// Guest architecture.
  final Xlen xlen;

  /// Guest RAM in megabytes.
  final int memorySizeMb;

  /// Kernel command line.
  final String cmdLine;

  /// Shell prompt string that marks a ready (and idle) console.
  final String shellPrompt;

  /// Network devices exposed to the guest.
  ///
  /// Empty (the default) is **air-gapped**: the guest has no network at
  /// all. For controlled connectivity, pass a `UserNetDevice` — supply
  /// it a filtering `NetBackend` to enforce an allow-list.
  final List<EthernetDevice> ethDevices;

  /// Optional VirtIO-9P shared folder mounted into the guest.
  ///
  /// Pass a directory-passthrough backend to share a host folder, or an
  /// in-memory backend (web-safe) to seed files. Host-side reads and
  /// writes go straight through the backend and appear in the guest at
  /// [sharedMountPoint] with no console round-trip. `null` (the default)
  /// exposes no share.
  final NinePShare? sharedFolder;

  /// Guest path where [sharedFolder] is mounted.
  final String sharedMountPoint;

  /// Whether `AgentSandbox.boot` mounts [sharedFolder] automatically.
  final bool autoMountShared;

  /// Time budget for `boot`.
  final Duration bootTimeout;

  /// Default wall-clock budget for `exec`.
  final Duration defaultTimeout;

  /// Default retired-instruction budget for `exec`
  /// (`null` = unlimited).
  final int? defaultMaxInstructions;
}
