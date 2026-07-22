/// Guest-workload benchmark for DartEMU.
///
/// Boots Linux with an in-memory rootfs (asset files are never mutated)
/// and measures wall time, retired instructions, and MIPS per phase.
/// Phases cover boot plus workloads that each stress a distinct
/// emulator subsystem: exec latency, process creation, shell CPU,
/// pipes, soft-float, sorting, compression, hashing, kernel memcpy,
/// and VirtIO block I/O.
///
/// Results across runs are aggregated as best/median/mean +- stddev,
/// with a coefficient-of-variation column to judge noise. Use `--json`
/// to save a baseline and `compare.dart` to diff two baselines.
///
/// Usage:
///   dart tool/bench/bench.dart [--xlen rv32|rv64] [--runs 3] [--json]
///   dart tool/bench/bench.dart --quick
///   dart tool/bench/bench.dart --workloads sh_loop_10k,disk_read_4m
///   dart tool/bench/bench.dart --list
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_emu/dart_emu.dart';

import 'src/runner.dart';
import 'src/stats.dart';
import 'src/workloads.dart';

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
    ..addOption(
      'workloads',
      help: 'Comma-separated workload names (default: all).',
    )
    ..addFlag('quick', help: 'Single run of a reduced workload set.')
    ..addFlag('json', help: 'Emit results as JSON.')
    ..addFlag('list', help: 'List available workloads and exit.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final options = parser.parse(args);
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  if (options['list'] as bool) {
    _printWorkloadList();
    return;
  }

  final quick = options['quick'] as bool;
  final xlen = options['xlen'] == 'rv32' ? Xlen.rv32 : Xlen.rv64;
  final runs = quick ? 1 : int.parse(options['runs'] as String);
  final assetsDir = options['assets'] as String;
  final asJson = options['json'] as bool;
  final workloads = _selectWorkloads(
    quick: quick,
    filter: options['workloads'] as String?,
  );

  final samplesPerRun = <List<PhaseSample>>[];
  for (var i = 0; i < runs; i++) {
    if (!asJson) stdout.writeln('run ${i + 1}/$runs...');
    samplesPerRun.add(
      BenchRunner(xlen: xlen, assetsDir: assetsDir, workloads: workloads).run(),
    );
  }

  final phases = _aggregate(samplesPerRun);
  _reportFailures(phases);

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(_toJson(xlen, runs, phases)),
    );
  } else {
    _printTable(xlen, runs, phases);
  }
}

List<Workload> _selectWorkloads({required bool quick, String? filter}) {
  final names =
      filter?.split(',').map((name) => name.trim()).toList() ??
      (quick ? Workloads.quick : null);
  if (names == null) return Workloads.all;

  final byName = {for (final w in Workloads.all) w.name: w};
  return names.map((name) {
    final workload = byName[name];
    if (workload == null) {
      stderr.writeln('Unknown workload "$name". Use --list to see options.');
      exit(2);
    }
    return workload;
  }).toList();
}

void _printWorkloadList() {
  stdout.writeln('Available workloads:');
  for (final workload in Workloads.all) {
    stdout.writeln(
      '  ${workload.name.padRight(_Report.nameWidth)}'
      '${workload.description}',
    );
  }
}

/// Aggregated statistics for one phase across all runs.
class PhaseResult {
  PhaseResult({
    required this.name,
    required this.wall,
    required this.instructions,
    required this.exitCodes,
  });

  final String name;
  final SampleStats wall;
  final SampleStats instructions;
  final List<int?> exitCodes;

  double get mipsBest => instructions.median / wall.best;
}

List<PhaseResult> _aggregate(List<List<PhaseSample>> samplesPerRun) {
  final phaseCount = samplesPerRun.first.length;
  return [
    for (var p = 0; p < phaseCount; p++)
      PhaseResult(
        name: samplesPerRun.first[p].name,
        wall: SampleStats([for (final run in samplesPerRun) run[p].wallMicros]),
        instructions: SampleStats([
          for (final run in samplesPerRun) run[p].instructions,
        ]),
        exitCodes: [for (final run in samplesPerRun) run[p].exitCode],
      ),
  ];
}

void _reportFailures(List<PhaseResult> phases) {
  for (final phase in phases) {
    final failed = phase.exitCodes.where((code) => code != null && code != 0);
    if (failed.isNotEmpty) {
      stderr.writeln(
        'WARNING: ${phase.name} exited non-zero in ${failed.length} run(s): '
        '${failed.join(', ')} — timings for this phase are not comparable.',
      );
    }
  }
}

void _printTable(Xlen xlen, int runs, List<PhaseResult> phases) {
  stdout
    ..writeln()
    ..writeln('DartEMU guest benchmark — ${xlen.name}, $runs run(s)')
    ..writeln()
    ..writeln(
      '${'phase'.padRight(_Report.nameWidth)}'
      '${'best'.padLeft(_Report.colWidth)}'
      '${'median'.padLeft(_Report.colWidth)}'
      '${'mean'.padLeft(_Report.colWidth)}'
      '${'cov'.padLeft(_Report.covWidth)}'
      '${'minst'.padLeft(_Report.colWidth)}'
      '${'mips'.padLeft(_Report.colWidth)}',
    );

  for (final phase in phases) {
    stdout.writeln(
      '${phase.name.padRight(_Report.nameWidth)}'
      '${_ms(phase.wall.best).padLeft(_Report.colWidth)}'
      '${_ms(phase.wall.median).padLeft(_Report.colWidth)}'
      '${_ms(phase.wall.mean).padLeft(_Report.colWidth)}'
      '${_pct(phase.wall.covPercent).padLeft(_Report.covWidth)}'
      '${_millions(phase.instructions.median).padLeft(_Report.colWidth)}'
      '${phase.mipsBest.toStringAsFixed(1).padLeft(_Report.colWidth)}',
    );
  }

  final totalBest = phases.fold<num>(0, (acc, p) => acc + p.wall.best);
  stdout
    ..writeln()
    ..writeln('total (best): ${_ms(totalBest)} ms')
    ..writeln(
      'note: "best" is least noisy; cov > ${_Report.noisyCovPercent}% '
      'means the phase is noisy on this host.',
    );
}

String _ms(num micros) =>
    (micros / Duration.microsecondsPerMillisecond).toStringAsFixed(1);

String _pct(double value) => '${value.toStringAsFixed(1)}%';

String _millions(num value) => (value / _Report.million).toStringAsFixed(1);

Map<String, Object> _toJson(Xlen xlen, int runs, List<PhaseResult> phases) => {
  'schema': _Report.schemaVersion,
  'meta': {
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystemVersion,
    'xlen': xlen.name,
    'runs': runs,
    'memory_mb': BenchDefaults.memorySizeMb,
    'cycles_per_step': BenchDefaults.cyclesPerStep,
  },
  'phases': [
    for (final phase in phases)
      {
        'name': phase.name,
        'wall_us': {
          'best': phase.wall.best,
          'median': phase.wall.median,
          'mean': phase.wall.mean,
          'stddev': phase.wall.stddev,
          'cov_pct': phase.wall.covPercent,
        },
        'instructions': {
          'median': phase.instructions.median,
          'best': phase.instructions.best,
          'worst': phase.instructions.worst,
        },
        'mips_best': phase.mipsBest,
        'exit_codes': phase.exitCodes,
      },
  ],
};

class _Report {
  static const schemaVersion = 1;
  static const nameWidth = 16;
  static const colWidth = 10;
  static const covWidth = 8;
  static const noisyCovPercent = 5;
  static const million = 1000000;
}
