import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';

import 'bench_console.dart';
import 'workloads.dart';

/// One measured phase within a single benchmark run.
class PhaseSample {
  PhaseSample({
    required this.name,
    required this.wallMicros,
    required this.instructions,
    this.exitCode,
  });

  /// Phase name (matches [Workload.name], or `boot`).
  final String name;

  /// Host wall-clock time for the phase.
  final int wallMicros;

  /// Guest instructions retired during the phase.
  final int instructions;

  /// Guest exit status of the workload command, if parseable.
  final int? exitCode;

  /// Emulation throughput in millions of instructions per second.
  double get mips => instructions / wallMicros;
}

/// Thrown when the guest fails to produce an expected marker in time.
class BenchTimeoutException implements Exception {
  BenchTimeoutException(this.marker, this.consoleTail);

  /// The marker that never appeared.
  final String marker;

  /// Recent console output for diagnostics.
  final String consoleTail;

  @override
  String toString() =>
      'BenchTimeoutException: timed out waiting for "$marker"\n'
      'last output:\n$consoleTail';
}

/// Boots a fresh machine and executes the workload suite once.
class BenchRunner {
  BenchRunner({
    required this.xlen,
    required this.assetsDir,
    required this.workloads,
  });

  /// Guest architecture for this run.
  final Xlen xlen;

  /// Directory containing bios/kernel/rootfs images.
  final String assetsDir;

  /// Workloads to execute after boot, in order.
  final List<Workload> workloads;

  late final RiscVMachine _machine;
  final BenchConsole _console = BenchConsole();
  int _sequence = 0;

  /// Boots the machine and runs every workload, returning one sample
  /// per phase (including the `boot` phase).
  List<PhaseSample> run() {
    final suffix = xlen == Xlen.rv32 ? '32' : '64';
    final config = MachineConfig(
      xlen: xlen,
      memorySizeMb: BenchDefaults.memorySizeMb,
      biosData: _readAsset('bbl$suffix.bin'),
      kernelData: _readAsset('kernel-riscv$suffix.bin'),
      cmdLine: BenchDefaults.cmdLine,
      console: _console,
      blockDevices: [MemoryBlockDevice(_readAsset('root-riscv$suffix.bin'))],
    );
    _machine = RiscVMachine.fromConfig(config);

    return [
      _measure('boot', marker: BenchDefaults.shellPrompt, parseExitCode: false),
      for (final workload in workloads) _runWorkload(workload),
    ];
  }

  Uint8List _readAsset(String name) =>
      File('$assetsDir/$name').readAsBytesSync();

  PhaseSample _runWorkload(Workload workload) {
    final sequence = _sequence++;
    _console.feedInput(utf8.encode('${workload.command(sequence)}\n'));
    return _measure(
      workload.name,
      marker: workload.marker(sequence),
      parseExitCode: true,
    );
  }

  PhaseSample _measure(
    String name, {
    required String marker,
    required bool parseExitCode,
  }) {
    _console.beginWait(marker);
    final startInstructions = _machine.cpu.state.instructionCounter;
    final stopwatch = Stopwatch()..start();

    while (!_console.markerFound()) {
      _machine.step(BenchDefaults.cyclesPerStep);
      if (stopwatch.elapsedMilliseconds > BenchDefaults.timeoutMs) {
        throw BenchTimeoutException(marker, _console.tail());
      }
    }

    stopwatch.stop();
    return PhaseSample(
      name: name,
      wallMicros: stopwatch.elapsedMicroseconds,
      instructions: _machine.cpu.state.instructionCounter - startInstructions,
      exitCode: parseExitCode ? _parseExitCode(_console.phaseOutput()) : null,
    );
  }

  int? _parseExitCode(String phaseOutput) {
    final match = _exitCodePattern.firstMatch(phaseOutput.trimRight());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static final _exitCodePattern = RegExp(r'(\d+):$');
}

/// Machine and harness parameters shared across runs.
class BenchDefaults {
  static const memorySizeMb = 128;
  static const cmdLine = 'console=hvc0 root=/dev/vda rw';
  static const shellPrompt = '~ #';
  static const cyclesPerStep = 50000;
  static const timeoutMs = 300000;
}
