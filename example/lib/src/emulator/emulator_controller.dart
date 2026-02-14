import 'dart:convert';

import 'package:dart_emu/dart_emu.dart';
import 'package:flutter/services.dart';

class _Assets {
  static const bios = 'assets/bbl64.bin';
  static const kernel = 'assets/kernel-riscv64.bin';
  static const rootfs = 'assets/root-riscv64.bin';
}

class _Defaults {
  static const cmdLine = 'console=hvc0 root=/dev/vda rw';
}

/// Manages the lifecycle of an [Emulator] instance in a Flutter context.
///
/// Loads VM images from Flutter assets and provides stream-based I/O
/// for connecting to a terminal widget.
class EmulatorController {
  Emulator? _emulator;

  /// Console output from the guest OS.
  Stream<Uint8List> get output =>
      _emulator?.output ?? const Stream.empty();

  /// Broadcast stream of emulator lifecycle status changes.
  Stream<EmulatorStatus> get status =>
      _emulator?.status ?? const Stream.empty();

  /// The current lifecycle status.
  EmulatorStatus get currentStatus =>
      _emulator?.currentStatus ?? EmulatorStatus.idle;

  /// Sends terminal input to the guest OS.
  void sendInput(String data) {
    _emulator?.sendInput(utf8.encode(data));
  }

  /// Loads VM images from assets and starts the emulation loop.
  Future<void> start() async {
    final results = await Future.wait([
      rootBundle.load(_Assets.bios),
      rootBundle.load(_Assets.kernel),
      rootBundle.load(_Assets.rootfs),
    ]);

    final biosData = results[0].buffer.asUint8List();
    final kernelData = results[1].buffer.asUint8List();
    final rootfsData = results[2].buffer.asUint8List();

    final config = MachineConfig(
      biosData: biosData,
      kernelData: kernelData,
      cmdLine: _Defaults.cmdLine,
      blockDevices: [MemoryBlockDevice(rootfsData)],
    );

    _emulator = Emulator(config);
    await _emulator!.start();
  }

  /// Disposes all resources and closes streams.
  Future<void> dispose() async {
    await _emulator?.dispose();
    _emulator = null;
  }
}
