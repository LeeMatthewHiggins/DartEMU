// Dumps dynamic micro-op pair frequencies.
// Run: dart -DDARTEMU_COUNT_PAIRS=true tool/bench/pair_stats.dart
import 'dart:io';

import 'package:dart_emu/dart_emu.dart';

import 'src/runner.dart';
import 'src/workloads.dart';

void main() {
  BenchRunner(
    xlen: Xlen.rv64,
    assetsDir: 'example/assets',
    workloads: Workloads.all,
  ).run();

  final counts = debugPredecodePairCounts();
  final entries = <(int, int)>[];
  var total = 0;
  for (var i = 0; i < counts.length; i++) {
    if (counts[i] > 0) {
      entries.add((i, counts[i]));
      total += counts[i];
    }
  }
  entries.sort((a, b) => b.$2.compareTo(a.$2));
  stdout.writeln('total dispatches: $total');
  for (final (key, count) in entries.take(25)) {
    final prev = key >> 8;
    final cur = key & 0xFF;
    final pct = (count / total * 100).toStringAsFixed(2);
    stdout.writeln('${_opName(prev)} -> ${_opName(cur)}: $pct%  ($count)');
  }
}

String _opName(int op) => _names[op] ?? 'op$op';

const _names = {
  1: 'fallback',
  2: 'nop',
  3: 'lui',
  4: 'auipc',
  5: 'addi',
  6: 'slti',
  7: 'sltiu',
  8: 'xori',
  9: 'ori',
  10: 'andi',
  11: 'slli',
  12: 'srli',
  13: 'srai',
  14: 'addiw',
  15: 'slliw',
  16: 'srliw',
  17: 'sraiw',
  18: 'add',
  19: 'sub',
  20: 'sll',
  21: 'slt',
  22: 'sltu',
  23: 'xor',
  24: 'srl',
  25: 'sra',
  26: 'or',
  27: 'and',
  28: 'addw',
  29: 'subw',
  30: 'sllw',
  31: 'srlw',
  32: 'sraw',
  33: 'mulDiv',
  34: 'mulDivW',
  35: 'jal',
  36: 'j',
  37: 'jalr',
  38: 'jr',
  39: 'beq',
  40: 'bne',
  41: 'blt',
  42: 'bge',
  43: 'bltu',
  44: 'bgeu',
  45: 'lb',
  46: 'lh',
  47: 'lw',
  48: 'ld',
  49: 'lbu',
  50: 'lhu',
  51: 'lwu',
  52: 'sb',
  53: 'sh',
  54: 'sw',
  55: 'sd',
};
