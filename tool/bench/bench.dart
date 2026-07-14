/// Guest-workload benchmark for DartEMU.
///
/// Boots Linux with an in-memory rootfs (asset files are never mutated),
/// measures wall time and retired instructions per phase, and reports
/// MIPS. Phases: boot to shell prompt, then a set of CPU-bound guest
/// workloads driven through the virtio console.
///
/// Usage:
///   dart tool/bench/bench.dart [--xlen rv32|rv64] [--runs 3] [--json]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:dart_emu/dart_emu.dart';

void main(List<String> args) {
  final parser = ArgParser()
    ..addOption(
      'xlen',
      allowed: ['rv32', 'rv64'],
      defaultsTo: 'rv32',
      help: 'Guest architecture.',
    )
    ..addOption(
      'runs',
      defaultsTo: '3',
      help: 'Number of full boot+workload runs.',
    )
    ..addOption(
      'assets',
      defaultsTo: 'example/assets',
      help: 'Directory containing bios/kernel/rootfs images.',
    )
    ..addFlag('json', help: 'Emit results as JSON.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final options = parser.parse(args);
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final xlen = options['xlen'] == 'rv32' ? Xlen.rv32 : Xlen.rv64;
  final runs = int.parse(options['runs'] as String);
  final assetsDir = options['assets'] as String;
  final asJson = options['json'] as bool;

  final results = <RunResult>[];
  for (var i = 0; i < runs; i++) {
    if (!asJson) stdout.writeln('run ${i + 1}/$runs...');
    results.add(BenchRunner(xlen: xlen, assetsDir: assetsDir).run());
  }

  if (asJson) {
    stdout.writeln(jsonEncode(_toJson(xlen, results)));
  } else {
    _printTable(xlen, results);
  }
}

class RunResult {
  RunResult(this.phases);

  final List<PhaseResult> phases;
}

class PhaseResult {
  PhaseResult({
    required this.name,
    required this.wallMicros,
    required this.instructions,
  });

  final String name;
  final int wallMicros;
  final int instructions;

  double get mips => instructions / wallMicros;
}

class BenchRunner {
  BenchRunner({required this.xlen, required this.assetsDir});

  final Xlen xlen;
  final String assetsDir;

  late final RiscVMachine _machine;
  final _BenchConsole _console = _BenchConsole();

  RunResult run() {
    final suffix = xlen == Xlen.rv32 ? '32' : '64';
    final config = MachineConfig(
      xlen: xlen,
      memorySizeMb: _Bench.memorySizeMb,
      biosData: _readAsset('bbl$suffix.bin'),
      kernelData: _readAsset('kernel-riscv$suffix.bin'),
      cmdLine: _Bench.cmdLine,
      console: _console,
      blockDevices: [
        MemoryBlockDevice(_readAsset('root-riscv$suffix.bin')),
      ],
    );
    _machine = RiscVMachine.fromConfig(config);

    final phases = <PhaseResult>[
      _measure('boot', () => _waitFor(_Bench.shellPrompt)),
      for (final workload in _Bench.workloads)
        _measure(workload.name, () => _runWorkload(workload)),
    ];
    return RunResult(phases);
  }

  Uint8List _readAsset(String name) =>
      File('$assetsDir/$name').readAsBytesSync();

  PhaseResult _measure(String name, void Function() body) {
    final startInstructions = _machine.cpu.state.instructionCounter;
    final stopwatch = Stopwatch()..start();
    body();
    stopwatch.stop();
    return PhaseResult(
      name: name,
      wallMicros: stopwatch.elapsedMicroseconds,
      instructions:
          _machine.cpu.state.instructionCounter - startInstructions,
    );
  }

  void _runWorkload(_Workload workload) {
    _console.feedInput(utf8.encode('${workload.command}\n'));
    _waitFor(workload.doneMarker);
  }

  void _waitFor(String marker) {
    final deadline = Stopwatch()..start();
    while (!_console.outputContains(marker)) {
      _machine.step(_Bench.cyclesPerStep);
      if (deadline.elapsedMilliseconds > _Bench.timeoutMs) {
        stderr
          ..writeln('timeout waiting for "$marker"; last output:')
          ..writeln(_console.tail());
        exit(1);
      }
    }
    _console.advanceCursor(marker);
  }
}

/// A guest shell command whose completion marker is computed at runtime
/// by the guest, so the tty echo of the typed command never contains
/// the literal marker text.
class _Workload {
  const _Workload(this.name, this.body);

  final String name;
  final String body;

  String get command => '$body; echo B\$(($_markerBase+$_markerAdd))E';

  String get doneMarker => 'B${_markerBase + _markerAdd}E';

  static const _markerBase = 663000;
  static const _markerAdd = 3;
}

class _Bench {
  static const memorySizeMb = 128;
  static const cmdLine = 'console=hvc0 root=/dev/vda rw';
  static const shellPrompt = '~ #';
  static const cyclesPerStep = 50000;
  static const timeoutMs = 180000;

  static const workloads = [
    _Workload(
      'sh_loop',
      r'i=0; while [ $i -lt 10000 ]; do i=$((i+1)); done',
    ),
    _Workload(
      'dd_64m',
      'dd if=/dev/zero of=/dev/null bs=65536 count=1024',
    ),
    _Workload(
      'fork_100',
      r'i=0; while [ $i -lt 100 ]; do /bin/true; i=$((i+1)); done',
    ),
  ];
}

class _BenchConsole implements CharacterDevice {
  final BytesBuilder _output = BytesBuilder();
  final List<int> _input = [];
  String _decoded = '';
  int _cursor = 0;

  void feedInput(List<int> bytes) => _input.addAll(bytes);

  bool outputContains(String marker) {
    _decoded = utf8.decode(_output.toBytes(), allowMalformed: true);
    return _decoded.indexOf(marker, _cursor) >= 0;
  }

  void advanceCursor(String marker) {
    final index = _decoded.indexOf(marker, _cursor);
    if (index >= 0) _cursor = index + marker.length;
  }

  String tail() {
    final text = utf8.decode(_output.toBytes(), allowMalformed: true);
    return text.length <= _tailLength
        ? text
        : text.substring(text.length - _tailLength);
  }

  @override
  void writeData(Uint8List data) => _output.add(data);

  @override
  Uint8List readData(int maxLength) {
    if (_input.isEmpty) return Uint8List(0);
    final count = maxLength < _input.length ? maxLength : _input.length;
    final result = Uint8List.fromList(_input.sublist(0, count));
    _input.removeRange(0, count);
    return result;
  }

  static const _tailLength = 600;
}

void _printTable(Xlen xlen, List<RunResult> results) {
  stdout
    ..writeln()
    ..writeln('DartEMU bench — ${xlen.name}, ${results.length} run(s)')
    ..writeln()
    ..writeln(
      '${'phase'.padRight(10)} ${'best ms'.padLeft(9)} '
      '${'median ms'.padLeft(10)} ${'instr (M)'.padLeft(10)} '
      '${'best MIPS'.padLeft(10)}',
    );

  final phaseCount = results.first.phases.length;
  for (var p = 0; p < phaseCount; p++) {
    final samples = [for (final r in results) r.phases[p]];
    final wallSorted = [...samples]
      ..sort((a, b) => a.wallMicros.compareTo(b.wallMicros));
    final best = wallSorted.first;
    final median = wallSorted[wallSorted.length ~/ 2];
    stdout.writeln(
      '${best.name.padRight(10)} '
      '${(best.wallMicros / 1000).toStringAsFixed(0).padLeft(9)} '
      '${(median.wallMicros / 1000).toStringAsFixed(0).padLeft(10)} '
      '${(best.instructions / 1e6).toStringAsFixed(1).padLeft(10)} '
      '${best.mips.toStringAsFixed(1).padLeft(10)}',
    );
  }
}

Map<String, Object> _toJson(Xlen xlen, List<RunResult> results) => {
      'xlen': xlen.name,
      'runs': [
        for (final r in results)
          {
            for (final p in r.phases)
              p.name: {
                'wall_us': p.wallMicros,
                'instructions': p.instructions,
                'mips': double.parse(p.mips.toStringAsFixed(2)),
              },
          },
      ],
    };
