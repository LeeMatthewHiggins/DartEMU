import 'dart:async';
import 'dart:convert';

import 'package:dart_emu/dart_emu.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class _Assets {
  static const bios32 = 'assets/bbl32.bin';
  static const kernel32 = 'assets/kernel-riscv32.bin';
  static const rootfs32 = 'assets/root-riscv32.bin';

  static const bios64 = 'assets/bbl64.bin';
  static const kernel64 = 'assets/kernel-riscv64.bin';
  static const rootfs64 = 'assets/root-riscv64.bin';

  static String bios(Xlen xlen) =>
      xlen == Xlen.rv32 ? bios32 : bios64;

  static String kernel(Xlen xlen) =>
      xlen == Xlen.rv32 ? kernel32 : kernel64;

  static String rootfs(Xlen xlen) =>
      xlen == Xlen.rv32 ? rootfs32 : rootfs64;
}

class _Defaults {
  static const cmdLine = 'console=hvc0 root=/dev/vda rw';
}

/// Manages the lifecycle of an [Emulator] instance in a Flutter context.
///
/// Uses a [Ticker] to drive emulation frame-by-frame, avoiding the
/// browser's `setTimeout` clamping that slows down `Future.delayed`
/// on the web.
class EmulatorController {
  /// Creates a controller that drives emulation via the given [vsync].
  EmulatorController({required TickerProvider vsync}) : _vsync = vsync;

  final TickerProvider _vsync;
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast();
  final StreamController<EmulatorStatus> _statusController =
      StreamController<EmulatorStatus>.broadcast();

  Emulator? _emulator;
  Ticker? _ticker;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<EmulatorStatus>? _statusSub;

  /// Console output from the guest OS.
  Stream<Uint8List> get output => _outputController.stream;

  /// Broadcast stream of emulator lifecycle status changes.
  Stream<EmulatorStatus> get status => _statusController.stream;

  /// The current lifecycle status.
  EmulatorStatus get currentStatus =>
      _emulator?.currentStatus ?? EmulatorStatus.idle;

  /// The error that caused an [EmulatorStatus.error] state, if any.
  Object? get lastError => _emulator?.lastError;

  /// Sends terminal input to the guest OS.
  void sendInput(String data) {
    _emulator?.sendInput(utf8.encode(data));
  }

  /// Loads VM images from bundled assets and starts emulation.
  Future<void> start({Xlen xlen = Xlen.rv64}) async {
    final results = await Future.wait([
      rootBundle.load(_Assets.bios(xlen)),
      rootBundle.load(_Assets.kernel(xlen)),
      rootBundle.load(_Assets.rootfs(xlen)),
    ]);

    final biosData = results[0].buffer.asUint8List();
    final kernelData = results[1].buffer.asUint8List();
    final rootfsData = results[2].buffer.asUint8List();

    final config = MachineConfig(
      xlen: xlen,
      biosData: biosData,
      kernelData: kernelData,
      cmdLine: _Defaults.cmdLine,
      blockDevices: [MemoryBlockDevice.fromData(rootfsData)],
      ethDevices: [UserNetDevice()],
    );

    await startWithConfig(config);
  }

  /// Starts emulation from a pre-resolved [MachineConfig].
  Future<void> startWithConfig(MachineConfig config) async {
    _emulator = Emulator(config);
    _outputSub = _emulator!.output.listen(_outputController.add);
    _statusSub = _emulator!.status.listen((status) {
      _statusController.add(status);
      if (status == EmulatorStatus.stopped ||
          status == EmulatorStatus.error) {
        _ticker?.stop();
      }
    });

    await _emulator!.init();
    if (_emulator!.currentStatus != EmulatorStatus.running) return;

    _ticker = _vsync.createTicker(_onTick);
    unawaited(_ticker!.start());
  }

  void _onTick(Duration elapsed) {
    _emulator?.stepFor(_frameBudgetMicros);
  }

  /// Disposes all resources and closes streams.
  Future<void> dispose() async {
    _ticker?.stop();
    _ticker?.dispose();
    await _outputSub?.cancel();
    await _statusSub?.cancel();
    await _emulator?.dispose();
    _emulator = null;
    await _outputController.close();
    await _statusController.close();
  }

  static const _frameBudgetMicros = 12000;
}
