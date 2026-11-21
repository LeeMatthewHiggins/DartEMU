@TestOn('vm')
@Tags(['machine'])
library;

import 'dart:typed_data';

import 'package:dart_emu/src/cpu/hot_loop_warmup.dart';
import 'package:dart_emu/src/cpu/predecode.dart';
import 'package:test/test.dart';

const _insnBytes = 4;
const _slotsPerInsn = 2;

/// The micro-op each warm-up instruction decodes to.
Set<int> _decodedOps() {
  final program = HotLoopWarmup.buildProgram();
  final source = ByteData(DecodedPage.slotCount * _slotsPerInsn);
  for (var i = 0; i < program.length; i++) {
    source.setUint32(i * _insnBytes, program[i], Endian.little);
  }
  final page = DecodedPage(source, 0);
  return {
    for (var i = 0; i < program.length; i++)
      Rv64Predecoder.decodeSlot(page, i * _slotsPerInsn) & PredecodeMeta.opMask,
  };
}

void main() {
  group('hot loop warm-up', () {
    test('exercises every micro-op the dispatch loop handles itself', () {
      // A micro-op missing here keeps its small-integer speculation, and
      // each such site costs the loop one of its sixteen deoptimizations.
      final expected = {
        for (var op = PredecodeOp.nop; op <= PredecodeOp.sd; op++) op,
      };

      expect(_decodedOps(), containsAll(expected));
    });

    test('contains nothing the loop hands to the fallback interpreter', () {
      expect(_decodedOps(), isNot(contains(PredecodeOp.fallback)));
    });

    test('runs without disturbing anything and only once', () {
      expect(HotLoopWarmup.ensure, returnsNormally);
      expect(HotLoopWarmup.ensure, returnsNormally);
    });
  });
}
