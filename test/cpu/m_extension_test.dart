@TestOn('vm')
library;

import 'dart:math';

import 'package:dart_emu/src/cpu/extensions/m_extension.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:test/test.dart';

class _Funct3 {
  static const mulh = 1;
  static const mulhsu = 2;
  static const mulhu = 3;
  static const divu = 5;
  static const remu = 7;
}

const _dwordBits = 64;
const _wordBits = 32;
const _minSigned64 = -9223372036854775808;
const _maxSigned64 = 9223372036854775807;
const _randomCases = 20000;

/// Operands chosen to sit on every boundary the 64-bit arithmetic has.
const List<int> _edges64 = [
  0,
  1,
  -1,
  2,
  -2,
  _minSigned64,
  _maxSigned64,
  0xFFFFFFFF,
  0x100000000,
  -0x100000000,
  0x7FFFFFFF,
  0x80000000,
];

const _edges32 = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFF, 0x10000];

BigInt _unsigned(int value, int bits) => BigInt.from(value).toUnsigned(bits);

BigInt _signed(int value, int bits) => BigInt.from(value).toSigned(bits);

/// The reference result, computed with arbitrary precision.
BigInt _reference(int funct3, int a, int b, int bits) {
  final ua = _unsigned(a, bits);
  final ub = _unsigned(b, bits);
  return switch (funct3) {
    _Funct3.mulh => (_signed(a, bits) * _signed(b, bits)) >> bits,
    _Funct3.mulhsu => (_signed(a, bits) * ub) >> bits,
    _Funct3.mulhu => (ua * ub) >> bits,
    _Funct3.divu => ub == BigInt.zero ? BigInt.from(-1) : ua ~/ ub,
    _ => ub == BigInt.zero ? ua : ua.remainder(ub),
  };
}

void _expectMatches(MExtension ext, int funct3, int a, int b, int bits) {
  final actual = ext.executeMulDiv(
    funct3: funct3,
    rs1Val: a,
    rs2Val: b,
    isWord: false,
  );
  expect(
    _unsigned(actual, bits),
    _reference(funct3, a, b, bits).toUnsigned(bits),
    reason: 'funct3=$funct3 a=$a b=$b',
  );
}

const List<int> _wideOps = [
  _Funct3.mulh,
  _Funct3.mulhsu,
  _Funct3.mulhu,
  _Funct3.divu,
  _Funct3.remu,
];

void main() {
  group('RV64 high multiply and unsigned divide', () {
    final ext = MExtension(xlen: Xlen.rv64);

    test('match arbitrary-precision results on every boundary pair', () {
      for (final funct3 in _wideOps) {
        for (final a in _edges64) {
          for (final b in _edges64) {
            _expectMatches(ext, funct3, a, b, _dwordBits);
          }
        }
      }
    });

    test('match arbitrary-precision results on random operands', () {
      final random = Random(64);
      int next() => (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32);
      for (var i = 0; i < _randomCases; i++) {
        final a = next();
        // A small divisor exercises the path where the quotient is large.
        final b = i.isEven ? next() : next() >>> random.nextInt(_dwordBits);
        for (final funct3 in _wideOps) {
          _expectMatches(ext, funct3, a, b, _dwordBits);
        }
      }
    });
  });

  group('RV32 high multiply', () {
    final ext = MExtension(xlen: Xlen.rv32);
    const ops = [_Funct3.mulh, _Funct3.mulhsu, _Funct3.mulhu];

    test('matches arbitrary-precision results on every boundary pair', () {
      for (final funct3 in ops) {
        for (final a in _edges32) {
          for (final b in _edges32) {
            _expectMatches(ext, funct3, a, b, _wordBits);
          }
        }
      }
    });

    test('matches arbitrary-precision results on random operands', () {
      final random = Random(32);
      for (var i = 0; i < _randomCases; i++) {
        final a = random.nextInt(1 << 32);
        final b = random.nextInt(1 << 32);
        for (final funct3 in ops) {
          _expectMatches(ext, funct3, a, b, _wordBits);
        }
      }
    });
  });

  group('word-sized encodings', () {
    test('only mulw, divw, divuw, remw and remuw exist', () {
      expect(
        [for (var f = 0; f < 8; f++) MExtension.isValidWordOp(f)],
        [true, false, false, false, true, true, true, true],
      );
    });
  });
}
