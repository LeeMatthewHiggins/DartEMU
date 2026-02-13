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
  static const wordBits = 32;
  static const dwordBits = 64;
  static const wordMask = 0xFFFFFFFF;
}

class MExtension {
  int executeMulDiv({
    required int funct3,
    required int rs1Val,
    required int rs2Val,
    required bool isWord,
  }) {
    if (isWord) {
      return _executeWord(funct3, rs1Val, rs2Val);
    }
    return _executeDword(funct3, rs1Val, rs2Val);
  }

  int _executeDword(int funct3, int rs1Val, int rs2Val) =>
      switch (funct3) {
        _Funct3.mul => _mul64(rs1Val, rs2Val),
        _Funct3.mulh => _mulh64(rs1Val, rs2Val),
        _Funct3.mulhsu => _mulhsu64(rs1Val, rs2Val),
        _Funct3.mulhu => _mulhu64(rs1Val, rs2Val),
        _Funct3.div => _div64(rs1Val, rs2Val),
        _Funct3.divu => _divu64(rs1Val, rs2Val),
        _Funct3.rem => _rem64(rs1Val, rs2Val),
        _Funct3.remu => _remu64(rs1Val, rs2Val),
        _ => throw ArgumentError('Invalid M funct3: $funct3'),
      };

  int _executeWord(int funct3, int rs1Val, int rs2Val) =>
      switch (funct3) {
        _Funct3.mul => _mulw(rs1Val, rs2Val),
        _Funct3.div => _divw(rs1Val, rs2Val),
        _Funct3.divu => _divuw(rs1Val, rs2Val),
        _Funct3.rem => _remw(rs1Val, rs2Val),
        _Funct3.remu => _remuw(rs1Val, rs2Val),
        _ => throw ArgumentError('Invalid M-W funct3: $funct3'),
      };

  int _mul64(int a, int b) => a * b;

  int _mulh64(int a, int b) {
    final product =
        BigInt.from(a) * BigInt.from(b);
    return (product >> _Limits.dwordBits).toInt();
  }

  int _mulhsu64(int a, int b) {
    final product =
        BigInt.from(a) *
        BigInt.from(b).toUnsigned(_Limits.dwordBits);
    return (product >> _Limits.dwordBits).toInt();
  }

  int _mulhu64(int a, int b) {
    final product =
        BigInt.from(a).toUnsigned(_Limits.dwordBits) *
        BigInt.from(b).toUnsigned(_Limits.dwordBits);
    return (product >> _Limits.dwordBits).toInt();
  }

  int _div64(int a, int b) {
    if (b == 0) return -1;
    if (a == _Limits.signedMin64 && b == -1) {
      return _Limits.signedMin64;
    }
    return a ~/ b;
  }

  int _divu64(int a, int b) {
    if (b == 0) return -1;
    final ua = BigInt.from(a).toUnsigned(_Limits.dwordBits);
    final ub = BigInt.from(b).toUnsigned(_Limits.dwordBits);
    return (ua ~/ ub).toInt();
  }

  int _rem64(int a, int b) {
    if (b == 0) return a;
    if (a == _Limits.signedMin64 && b == -1) return 0;
    return a.remainder(b);
  }

  int _remu64(int a, int b) {
    if (b == 0) return a;
    final ua = BigInt.from(a).toUnsigned(_Limits.dwordBits);
    final ub = BigInt.from(b).toUnsigned(_Limits.dwordBits);
    return ua.remainder(ub).toInt();
  }

  int _mulw(int a, int b) =>
      _signExtend32(_truncate32(a) * _truncate32(b));

  int _divw(int a, int b) {
    final sa = _truncate32(a);
    final sb = _truncate32(b);
    if (sb == 0) return -1;
    if (sa == _Limits.signedMin32 && sb == -1) {
      return _Limits.signedMin32;
    }
    return sa ~/ sb;
  }

  int _divuw(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return -1;
    return _signExtend32(ua ~/ ub);
  }

  int _remw(int a, int b) {
    final sa = _truncate32(a);
    final sb = _truncate32(b);
    if (sb == 0) return sa;
    if (sa == _Limits.signedMin32 && sb == -1) return 0;
    return sa.remainder(sb);
  }

  int _remuw(int a, int b) {
    final ua = a & _Limits.wordMask;
    final ub = b & _Limits.wordMask;
    if (ub == 0) return _signExtend32(ua);
    final result = ua.remainder(ub);
    return _signExtend32(result);
  }

  int _truncate32(int value) =>
      (value & _Limits.wordMask).toSigned(_Limits.wordBits);

  int _signExtend32(int value) =>
      (value & _Limits.wordMask).toSigned(_Limits.wordBits);
}
