import 'package:dart_emu/src/machine/machine_config.dart';

abstract class MExtension {
  factory MExtension({required Xlen xlen}) => switch (xlen) {
    Xlen.rv32 => _MExtension32(),
    Xlen.rv64 => _MExtension64(),
  };

  MExtension._();

  /// Whether [funct3] names a real `*W` instruction. RV64 defines only
  /// `mulw`, `divw`, `divuw`, `remw` and `remuw`; the encodings where
  /// `mulh`, `mulhsu` and `mulhu` would sit are reserved and must trap.
  static bool isValidWordOp(int funct3) =>
      funct3 == _Funct3.mul || funct3 >= _Funct3.div;

  int executeMulDiv({
    required int funct3,
    required int rs1Val,
    required int rs2Val,
    required bool isWord,
  });
}

class _MExtension64 extends MExtension {
  _MExtension64() : super._();

  @override
  int executeMulDiv({
    required int funct3,
    required int rs1Val,
    required int rs2Val,
    required bool isWord,
  }) {
    if (isWord) return _executeWord(funct3, rs1Val, rs2Val);
    return _executeDword(funct3, rs1Val, rs2Val);
  }

  int _executeDword(int funct3, int a, int b) => switch (funct3) {
    _Funct3.mul => a * b,
    _Funct3.mulh => _mulh64(a, b),
    _Funct3.mulhsu => _mulhsu64(a, b),
    _Funct3.mulhu => _mulhu64(a, b),
    _Funct3.div => _div64(a, b),
    _Funct3.divu => _divu64(a, b),
    _Funct3.rem => _rem64(a, b),
    _Funct3.remu => _remu64(a, b),
    _ => throw ArgumentError('Invalid M funct3: $funct3'),
  };

  int _executeWord(int funct3, int a, int b) => switch (funct3) {
    _Funct3.mul => _mulw(a, b),
    _Funct3.div => _divw(a, b),
    _Funct3.divu => _divuw(a, b),
    _Funct3.rem => _remw(a, b),
    _Funct3.remu => _remuw(a, b),
    _ => throw ArgumentError('Invalid M-W funct3: $funct3'),
  };

  static int _mulh64(int a, int b) =>
      _mulhu64(a, b) - (a < 0 ? b : 0) - (b < 0 ? a : 0);

  static int _mulhsu64(int a, int b) => _mulhu64(a, b) - (a < 0 ? b : 0);

  /// High 64 bits of the unsigned 128-bit product, from four 32x32
  /// partial products. Each partial product fits in 64 bits, and the
  /// wrap-around of native integers is exactly unsigned arithmetic.
  static int _mulhu64(int a, int b) {
    final aLo = a & _Limits.wordMask;
    final aHi = a >>> _Bits.word;
    final bLo = b & _Limits.wordMask;
    final bHi = b >>> _Bits.word;
    final lowHigh = aLo * bHi;
    final highLow = aHi * bLo;
    final carry =
        ((aLo * bLo) >>> _Bits.word) +
        (lowHigh & _Limits.wordMask) +
        (highLow & _Limits.wordMask);
    return aHi * bHi +
        (lowHigh >>> _Bits.word) +
        (highLow >>> _Bits.word) +
        (carry >>> _Bits.word);
  }

  static bool _unsignedLess(int a, int b) =>
      (a ^ _Limits.signedMin64) < (b ^ _Limits.signedMin64);

  /// Unsigned quotient for a divisor below 2^63. A dividend with the top
  /// bit set is halved first so the native signed division applies, which
  /// leaves the quotient at most one short.
  static int _unsignedQuotient(int a, int b) {
    if (a >= 0) return a ~/ b;
    final estimate = ((a >>> 1) ~/ b) << 1;
    return _unsignedLess(a - estimate * b, b) ? estimate : estimate + 1;
  }

  static int _div64(int a, int b) {
    if (b == 0) return -1;
    if (a == _Limits.signedMin64 && b == -1) return _Limits.signedMin64;
    return a ~/ b;
  }

  static int _divu64(int a, int b) {
    if (b == 0) return -1;
    if (b < 0) return _unsignedLess(a, b) ? 0 : 1;
    return _unsignedQuotient(a, b);
  }

  static int _rem64(int a, int b) {
    if (b == 0) return a;
    if (a == _Limits.signedMin64 && b == -1) return 0;
    return a.remainder(b);
  }

  static int _remu64(int a, int b) {
    if (b == 0) return a;
    if (b < 0) return _unsignedLess(a, b) ? a : a - b;
    return a - _unsignedQuotient(a, b) * b;
  }

  static int _mulw(int a, int b) =>
      _signExtend32(_truncate32(a) * _truncate32(b));

  static int _divw(int a, int b) {
    final sa = _truncate32(a);
    final sb = _truncate32(b);
    if (sb == 0) return -1;
    if (sa == _Limits.signedMin32 && sb == -1) return _Limits.signedMin32;
    return sa ~/ sb;
  }

  static int _divuw(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return -1;
    return _signExtend32(ua ~/ ub);
  }

  static int _remw(int a, int b) {
    final sa = _truncate32(a);
    final sb = _truncate32(b);
    if (sb == 0) return sa;
    if (sa == _Limits.signedMin32 && sb == -1) return 0;
    return sa.remainder(sb);
  }

  static int _remuw(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return _signExtend32(ua);
    return _signExtend32(ua.remainder(ub));
  }

  static int _truncate32(int value) =>
      (value & _Limits.wordMask).toSigned(_Bits.word);

  static int _signExtend32(int value) =>
      (value & _Limits.wordMask).toSigned(_Bits.word);
}

class _MExtension32 extends MExtension {
  _MExtension32() : super._();

  @override
  int executeMulDiv({
    required int funct3,
    required int rs1Val,
    required int rs2Val,
    required bool isWord,
  }) => switch (funct3) {
    _Funct3.mul => _mul(rs1Val, rs2Val),
    _Funct3.mulh => _mulh(rs1Val, rs2Val),
    _Funct3.mulhsu => _mulhsu(rs1Val, rs2Val),
    _Funct3.mulhu => _mulhu(rs1Val, rs2Val),
    _Funct3.div => _div(rs1Val, rs2Val),
    _Funct3.divu => _divu(rs1Val, rs2Val),
    _Funct3.rem => _rem(rs1Val, rs2Val),
    _Funct3.remu => _remu(rs1Val, rs2Val),
    _ => throw ArgumentError('Invalid M funct3: $funct3'),
  };

  /// Uses split-multiply to produce correct lower 32 bits
  /// without exceeding JS safe integer range.
  static int _mul(int a, int b) {
    final aLo = a & _Half.mask;
    final aHi = (a >> _Half.bits) & _Half.mask;
    final bLo = b & _Half.mask;
    final bHi = (b >> _Half.bits) & _Half.mask;
    final lo = aLo * bLo;
    final cross = aLo * bHi + aHi * bLo;
    return (lo + ((cross & _Half.mask) << _Half.bits)) & _Limits.wordMask;
  }

  static bool _isNegative(int value) => (value & _Limits.signBit32) != 0;

  static int _mulh(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    final high =
        _mulhu(ua, ub) -
        (_isNegative(ua) ? ub : 0) -
        (_isNegative(ub) ? ua : 0);
    return high & _Limits.wordMask;
  }

  static int _mulhsu(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    return (_mulhu(ua, ub) - (_isNegative(ua) ? ub : 0)) & _Limits.wordMask;
  }

  /// High 32 bits of the unsigned 64-bit product, from 16-bit halves so
  /// every intermediate stays inside the JavaScript safe-integer range.
  static int _mulhu(int a, int b) {
    final aLo = a & _Half.mask;
    final aHi = (a >>> _Half.bits) & _Half.mask;
    final bLo = b & _Half.mask;
    final bHi = (b >>> _Half.bits) & _Half.mask;
    final lowHigh = aLo * bHi;
    final highLow = aHi * bLo;
    final carry =
        ((aLo * bLo) >>> _Half.bits) +
        (lowHigh & _Half.mask) +
        (highLow & _Half.mask);
    return aHi * bHi +
        (lowHigh >>> _Half.bits) +
        (highLow >>> _Half.bits) +
        (carry >>> _Half.bits);
  }

  static int _div(int a, int b) {
    final sa = a.toSigned(_Bits.word);
    final sb = b.toSigned(_Bits.word);
    if (sb == 0) return -1;
    if (sa == _Limits.signedMin32 && sb == -1) return _Limits.signedMin32;
    return sa ~/ sb;
  }

  static int _divu(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return -1;
    return ua ~/ ub;
  }

  static int _rem(int a, int b) {
    final sa = a.toSigned(_Bits.word);
    final sb = b.toSigned(_Bits.word);
    if (sb == 0) return sa;
    if (sa == _Limits.signedMin32 && sb == -1) return 0;
    return sa.remainder(sb);
  }

  static int _remu(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return ua;
    return ua.remainder(ub);
  }
}

class _Funct3 {
  static const mul = 0;
  static const mulh = 1;
  static const mulhsu = 2;
  static const mulhu = 3;
  static const div = 4;
  static const divu = 5;
  static const rem = 6;
  static const remu = 7;
}

class _Limits {
  static const signedMin64 = -9223372036854775808;
  static const signedMin32 = -2147483648;
  static const wordMask = 0xFFFFFFFF;
  static const signBit32 = 0x80000000;
}

class _Bits {
  static const word = 32;
}

class _Half {
  static const bits = 16;
  static const mask = 0xFFFF;
}
