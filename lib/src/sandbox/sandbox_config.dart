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
    required this.biosData,
    required this.kernelData,
    required this.rootfsData,
    this.xlen = Xlen.rv64,
    this.memorySizeMb = 128,
    this.cmdLine = 'console=hvc0 root=/dev/vda rw',
    this.shellPrompt = '~ # ',
    this.ethDevices = const [],
    this.bootTimeout = const Duration(seconds: 30),
    this.defaultTimeout = const Duration(seconds: 30),
    this.defaultMaxInstructions,
  });

  /// Bootloader (BBL/OpenSBI) image.
  final Uint8List biosData;

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

  /// Time budget for `boot`.
  final Duration bootTimeout;

  /// Default wall-clock budget for `exec`.
  final Duration defaultTimeout;

  /// Default retired-instruction budget for `exec`
  /// (`null` = unlimited).
  final int? defaultMaxInstructions;
}
