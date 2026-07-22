import 'dart:math' as math;

/// Summary statistics over a set of per-run samples.
class SampleStats {
  SampleStats(List<num> samples)
    : assert(samples.isNotEmpty, 'samples must not be empty'),
      best = samples.reduce(math.min),
      worst = samples.reduce(math.max),
      mean = _mean(samples),
      median = _median(samples),
      stddev = _stddev(samples);

  /// The minimum sample — least affected by host noise.
  final num best;

  /// The maximum sample.
  final num worst;

  /// The arithmetic mean.
  final double mean;

  /// The median sample.
  final num median;

  /// The population standard deviation.
  final double stddev;

  /// Coefficient of variation as a percentage of the mean.
  double get covPercent => mean == 0 ? 0 : stddev / mean * _percent;

  static double _mean(List<num> samples) =>
      samples.fold<num>(0, (a, b) => a + b) / samples.length;

  static num _median(List<num> samples) {
    final sorted = List<num>.of(samples)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _stddev(List<num> samples) {
    final mean = _mean(samples);
    final sumSquares = samples.fold<double>(0, (acc, sample) {
      final delta = sample - mean;
      return acc + delta * delta;
    });
    return math.sqrt(sumSquares / samples.length);
  }

  static const _percent = 100;
}
