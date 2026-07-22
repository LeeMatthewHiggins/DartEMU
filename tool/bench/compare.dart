/// Compares two benchmark baselines produced by `bench.dart --json`.
///
/// For each phase present in both files, reports the change in best
/// wall time and flags it as faster/slower only when the delta exceeds
/// the measured noise (coefficient of variation) of both baselines.
///
/// Usage:
///   dart tool/bench/bench.dart --json > before.json
///   ... make changes ...
///   dart tool/bench/bench.dart --json > after.json
///   dart tool/bench/compare.dart before.json after.json
///
/// Exits non-zero with `--fail-on-regress <pct>` if any phase regresses
/// by more than the given percentage (for CI gates).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';

void main(List<String> args) {
  final parser = ArgParser()
    ..addOption(
      'fail-on-regress',
      help: 'Exit non-zero if any phase regresses by more than this percent.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final options = parser.parse(args);
  if (options['help'] as bool || options.rest.length != 2) {
    stdout
      ..writeln(
        'Usage: dart tool/bench/compare.dart <before.json> '
        '<after.json>',
      )
      ..writeln(parser.usage);
    exit(options['help'] as bool ? 0 : 2);
  }

  final before = _Baseline.load(options.rest[0]);
  final after = _Baseline.load(options.rest[1]);
  final failThreshold = _parseThreshold(options['fail-on-regress'] as String?);

  _checkComparability(before, after);

  final rows = <_ComparisonRow>[];
  for (final name in before.phaseNames) {
    final basePhase = before.phase(name);
    final candPhase = after.phase(name);
    if (candPhase == null) {
      stderr.writeln('note: phase "$name" missing from after file; skipped.');
      continue;
    }
    rows.add(_ComparisonRow(base: basePhase!, candidate: candPhase));
  }
  for (final name in after.phaseNames) {
    if (before.phase(name) == null) {
      stderr.writeln('note: phase "$name" missing from before file; skipped.');
    }
  }

  _printTable(before, after, rows);

  if (failThreshold != null) {
    final regressed = rows
        .where((row) => row.isSignificant && row.deltaPercent > failThreshold)
        .toList();
    if (regressed.isNotEmpty) {
      stderr.writeln(
        'FAIL: ${regressed.map((r) => r.name).join(', ')} regressed beyond '
        '$failThreshold%.',
      );
      exit(1);
    }
  }
}

double? _parseThreshold(String? raw) {
  if (raw == null) return null;
  final value = double.tryParse(raw);
  if (value == null) {
    stderr.writeln('Invalid --fail-on-regress value: "$raw"');
    exit(2);
  }
  return value;
}

void _checkComparability(_Baseline before, _Baseline after) {
  if (before.xlen != after.xlen) {
    stderr.writeln(
      'WARNING: comparing different architectures '
      '(${before.xlen} vs ${after.xlen}).',
    );
  }
  if (before.os != after.os) {
    stderr.writeln('WARNING: baselines were recorded on different hosts.');
  }
}

class _Baseline {
  _Baseline._(this.path, this._json);

  factory _Baseline.load(String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(File(path).readAsStringSync());
    } on FileSystemException catch (e) {
      stderr.writeln('Cannot read $path: ${e.message}');
      exit(2);
    } on FormatException catch (e) {
      stderr.writeln('$path is not valid JSON: ${e.message}');
      exit(2);
    }
    return _Baseline._(path, decoded! as Map<String, dynamic>);
  }

  final String path;
  final Map<String, dynamic> _json;

  Map<String, dynamic> get _meta => _json['meta'] as Map<String, dynamic>;

  String get xlen => _meta['xlen'] as String;

  String get os => _meta['os'] as String;

  String get timestamp => _meta['timestamp'] as String;

  List<Map<String, dynamic>> get _phases =>
      (_json['phases'] as List).cast<Map<String, dynamic>>();

  Iterable<String> get phaseNames =>
      _phases.map((phase) => phase['name'] as String);

  _Phase? phase(String name) {
    for (final entry in _phases) {
      if (entry['name'] == name) return _Phase(entry);
    }
    return null;
  }
}

class _Phase {
  _Phase(this._json);

  final Map<String, dynamic> _json;

  String get name => _json['name'] as String;

  Map<String, dynamic> get _wall => _json['wall_us'] as Map<String, dynamic>;

  num get bestMicros => _wall['best'] as num;

  double get covPercent => (_wall['cov_pct'] as num).toDouble();

  double get mipsBest => (_json['mips_best'] as num).toDouble();
}

class _ComparisonRow {
  _ComparisonRow({required this.base, required this.candidate});

  final _Phase base;
  final _Phase candidate;

  String get name => base.name;

  /// Positive means the candidate is slower.
  double get deltaPercent =>
      (candidate.bestMicros - base.bestMicros) / base.bestMicros * 100;

  /// The noise floor: deltas within this band are not meaningful.
  double get noisePercent => math.max(
    _Thresholds.minimumNoisePercent,
    _Thresholds.covMultiplier * math.max(base.covPercent, candidate.covPercent),
  );

  bool get isSignificant => deltaPercent.abs() > noisePercent;

  String get verdict {
    if (!isSignificant) return '~';
    return deltaPercent < 0 ? 'FASTER' : 'SLOWER';
  }
}

void _printTable(_Baseline before, _Baseline after, List<_ComparisonRow> rows) {
  stdout
    ..writeln()
    ..writeln('before: ${before.path} (${before.xlen}, ${before.timestamp})')
    ..writeln('after:  ${after.path} (${after.xlen}, ${after.timestamp})')
    ..writeln()
    ..writeln(
      '${'phase'.padRight(_Format.nameWidth)}'
      '${'before'.padLeft(_Format.colWidth)}'
      '${'after'.padLeft(_Format.colWidth)}'
      '${'delta'.padLeft(_Format.colWidth)}'
      '${'noise'.padLeft(_Format.colWidth)}'
      '${'mips'.padLeft(_Format.colWidth)}'
      '  verdict',
    );

  for (final row in rows) {
    final sign = row.deltaPercent >= 0 ? '+' : '';
    final delta = '$sign${row.deltaPercent.toStringAsFixed(1)}%';
    final noise = '±${row.noisePercent.toStringAsFixed(1)}%';
    stdout.writeln(
      '${row.name.padRight(_Format.nameWidth)}'
      '${_ms(row.base.bestMicros).padLeft(_Format.colWidth)}'
      '${_ms(row.candidate.bestMicros).padLeft(_Format.colWidth)}'
      '${delta.padLeft(_Format.colWidth)}'
      '${noise.padLeft(_Format.colWidth)}'
      '${row.candidate.mipsBest.toStringAsFixed(1).padLeft(_Format.colWidth)}'
      '  ${row.verdict}',
    );
  }

  final significant = rows.where((row) => row.isSignificant).toList();
  final faster = significant.where((row) => row.deltaPercent < 0).length;
  final slower = significant.length - faster;
  final geomean = _geomeanDelta(rows);
  stdout
    ..writeln()
    ..writeln(
      'summary: $faster faster, $slower slower, '
      '${rows.length - significant.length} within noise; '
      'geomean delta ${geomean >= 0 ? '+' : ''}${geomean.toStringAsFixed(1)}%',
    );
}

double _geomeanDelta(List<_ComparisonRow> rows) {
  if (rows.isEmpty) return 0;
  var logSum = 0.0;
  for (final row in rows) {
    logSum += math.log(row.candidate.bestMicros / row.base.bestMicros);
  }
  return (math.exp(logSum / rows.length) - 1) * 100;
}

String _ms(num micros) =>
    (micros / Duration.microsecondsPerMillisecond).toStringAsFixed(1);

class _Thresholds {
  static const minimumNoisePercent = 2.0;
  static const covMultiplier = 2.0;
}

class _Format {
  static const nameWidth = 16;
  static const colWidth = 10;
}
