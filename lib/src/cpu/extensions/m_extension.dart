import 'package:dart_emu/src/machine/machine_config.dart';

abstract class MExtension {
  factory MExtension({required Xlen xlen}) => switch (xlen) {
    Xlen.rv32 => _MExtension32(),
    Xlen.rv64 => _MExtension64(),
  };

  MExtension._();

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
      (BigInt.from(a) * BigInt.from(b) >> _Bits.dword).toInt();

  static int _mulhsu64(int a, int b) =>
      (BigInt.from(a) *
              BigInt.from(b).toUnsigned(_Bits.dword) >>
          _Bits.dword)
      .toInt();

  static int _mulhu64(int a, int b) =>
      (BigInt.from(a).toUnsigned(_Bits.dword) *
              BigInt.from(b).toUnsigned(_Bits.dword) >>
          _Bits.dword)
      .toInt();

  static int _div64(int a, int b) {
    if (b == 0) return -1;
    if (a == _Limits.signedMin64 && b == -1) return _Limits.signedMin64;
    return a ~/ b;
  }

  static int _divu64(int a, int b) {
    if (b == 0) return -1;
    return (BigInt.from(a).toUnsigned(_Bits.dword) ~/
            BigInt.from(b).toUnsigned(_Bits.dword))
        .toInt();
  }

  static int _rem64(int a, int b) {
    if (b == 0) return a;
    if (a == _Limits.signedMin64 && b == -1) return 0;
    return a.remainder(b);
  }

  static int _remu64(int a, int b) {
    if (b == 0) return a;
    return BigInt.from(a)
        .toUnsigned(_Bits.dword)
        .remainder(BigInt.from(b).toUnsigned(_Bits.dword))
        .toInt();
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
  }) =>
      switch (funct3) {
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
    return (lo + ((cross & _Half.mask) << _Half.bits)) &
        _Limits.wordMask;
  }

  static int _mulh(int a, int b) =>
      (BigInt.from(a.toSigned(_Bits.word)) *
              BigInt.from(b.toSigned(_Bits.word)) >>
          _Bits.word)
      .toInt();

  static int _mulhsu(int a, int b) =>
      (BigInt.from(a.toSigned(_Bits.word)) *
              BigInt.from(b).toUnsigned(_Bits.word) >>
          _Bits.word)
      .toInt();

  static int _mulhu(int a, int b) =>
      (BigInt.from(a).toUnsigned(_Bits.word) *
              BigInt.from(b).toUnsigned(_Bits.word) >>
          _Bits.word)
      .toInt();

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
}

class _Bits {
  static const word = 32;
  static const dword = 64;
}

class _Half {
  static const bits = 16;
  static const mask = 0xFFFF;
}
