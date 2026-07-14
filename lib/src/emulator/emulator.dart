import 'dart:async';
import 'dart:typed_data';

import 'package:dart_emu/src/emulator/emulator_status.dart';
import 'package:dart_emu/src/emulator/stream_console_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';

/// Facade for the DartEMU RISC-V emulator.
///
/// Provides stream-based console I/O and lifecycle management,
/// suitable for embedding in both CLI and Flutter applications.
///
/// Two execution modes are supported:
/// - **Loop mode** via [start]: runs an internal async loop, suitable for CLI.
/// - **Frame mode** via [init] + [stepFor]: caller drives execution per frame,
///   suitable for Flutter with a `Ticker`.
class Emulator {
  /// Creates an emulator with the given [config].
  ///
  /// The [config] should not have a `console` set; the emulator
  /// manages its own stream-backed console device internally.
  Emulator(MachineConfig config) : _userConfig = config;

  final MachineConfig _userConfig;
  final StreamConsoleDevice _consoleDevice = StreamConsoleDevice();
  final StreamController<EmulatorStatus> _statusController =
      StreamController<EmulatorStatus>.broadcast();

  RiscVMachine? _machine;
  EmulatorStatus _currentStatus = EmulatorStatus.idle;
  Object? _lastError;

  /// Console output from the guest OS.
  Stream<Uint8List> get output => _consoleDevice.outputStream;

  /// Sends console input bytes to the guest OS.
  void sendInput(List<int> bytes) {
    _consoleDevice.feedInput(bytes);
  }

  /// Broadcast stream of lifecycle status changes.
  Stream<EmulatorStatus> get status => _statusController.stream;

  /// The current lifecycle status.
  EmulatorStatus get currentStatus => _currentStatus;

  /// The error that caused an [EmulatorStatus.error] state, if any.
  Object? get lastError => _lastError;

  /// Initialises the virtual machine without starting execution.
  ///
  /// After this returns with [currentStatus] == [EmulatorStatus.running],
  /// call [stepFor] repeatedly (e.g. from a `Ticker`) to drive execution.
  Future<void> init() async {
    if (_currentStatus != EmulatorStatus.idle) {
      throw StateError(
        'Emulator cannot be initialised from $_currentStatus state',
      );
    }

    _setStatus(EmulatorStatus.starting);

    try {
      final config = _userConfig.copyWith(console: _consoleDevice);
      _machine = RiscVMachine.fromConfig(config);
    } on Object catch (error) {
      _lastError = error;
      _setStatus(EmulatorStatus.error);
      return;
    }

    _setStatus(EmulatorStatus.running);
  }

  /// Executes guest instructions for up to [budgetMicroseconds].
  ///
  /// Runs batches of [_cyclesPerStep] cycles, checking timers and console
  /// I/O between batches, until the time budget is exhausted or the guest
  /// enters power-down / shutdown.
  void stepFor(int budgetMicroseconds) {
    final machine = _machine;
    if (machine == null || _currentStatus != EmulatorStatus.running) return;

    try {
      if (machine.cpu.state.shutDown) {
        _setStatus(EmulatorStatus.stopped);
        return;
      }

      if (machine.cpu.state.powerDown) {
        machine.step(0);
        return;
      }

      final sw = Stopwatch()..start();
      do {
        machine.step(_cyclesPerStep);
        if (machine.cpu.state.shutDown) {
          _setStatus(EmulatorStatus.stopped);
          return;
        }
        if (machine.cpu.state.powerDown) return;
      } while (sw.elapsedMicroseconds < budgetMicroseconds);
    } on Object catch (error) {
      _lastError = error;
      _setStatus(EmulatorStatus.error);
    }
  }

  /// Starts the emulation loop.
  ///
  /// Returns a [Future] that completes when the machine shuts down,
  /// either from a guest power-off or a call to [stop]. Suitable for
  /// CLI usage where the caller can await completion.
  Future<void> start() async {
    await init();
    if (_currentStatus != EmulatorStatus.running) return;

    try {
      final machine = _machine!;
      while (!machine.cpu.state.shutDown) {
        machine.step(_cyclesPerStep);
        final delay = machine.cpu.state.powerDown
            ? _idleDelay
            : _activeDelay;
        await Future<void>.delayed(delay);
      }
    } on Object catch (error) {
      _lastError = error;
      _setStatus(EmulatorStatus.error);
      return;
    }

    _setStatus(EmulatorStatus.stopped);
  }

  /// Signals the emulator to shut down gracefully.
  void stop() {
    _machine?.cpu.state.shutDown = true;
  }

  /// Disposes all resources and closes streams.
  Future<void> dispose() async {
    stop();
    await _consoleDevice.dispose();
    await _statusController.close();
  }

  void _setStatus(EmulatorStatus newStatus) {
    _currentStatus = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  static const _cyclesPerStep = 50000;
  static const _activeDelay = Duration.zero;
  static const _idleDelay = Duration(milliseconds: 10);
}
