import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_emu/src/cpu/softfp/soft_float.dart';

final ByteData _scratch = ByteData(8);

double _toDouble(int bits32) {
  _scratch.setUint32(0, bits32 & _Float32Bits.fullMask, Endian.little);
  return _scratch.getFloat32(0, Endian.little);
}

int _fromDouble(double val) {
  _scratch.setFloat32(0, val, Endian.little);
  return _scratch.getUint32(0, Endian.little);
}

bool _isNaN(int bits) {
  final exp = (bits & _Float32Bits.expMask) >> _Float32Bits.expShift;
  final mant = bits & _Float32Bits.mantMask;
  return exp == _Float32Bits.biasedExpMax && mant != 0;
}

bool _isSNaN(int bits) {
  if (!_isNaN(bits)) return false;
  return (bits & _Float32Bits.qNanBit) == 0;
}

bool _isInf(int bits) {
  final exp = (bits & _Float32Bits.expMask) >> _Float32Bits.expShift;
  final mant = bits & _Float32Bits.mantMask;
  return exp == _Float32Bits.biasedExpMax && mant == 0;
}

class SoftFloat32 {
  const SoftFloat32._();

  static int add(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) || _isNaN(b)) return _Float32Bits.canonicalNaN;

    final result = _toDouble(a) + _toDouble(b);
    return _roundResult(result, flags);
  }

  static int sub(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) || _isNaN(b)) return _Float32Bits.canonicalNaN;

    final result = _toDouble(a) - _toDouble(b);
    return _roundResult(result, flags);
  }

  static int mul(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) || _isNaN(b)) return _Float32Bits.canonicalNaN;

    if ((_isInf(a) && _toDouble(b) == 0) ||
        (_isInf(b) && _toDouble(a) == 0)) {
      flags.add(FpFlags.invalidOp);
      return _Float32Bits.canonicalNaN;
    }

    final result = _toDouble(a) * _toDouble(b);
    return _roundResult(result, flags);
  }

  static int div(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) || _isNaN(b)) return _Float32Bits.canonicalNaN;

    final da = _toDouble(a);
    final db = _toDouble(b);

    if (db == 0) {
      if (da == 0) {
        flags.add(FpFlags.invalidOp);
        return _Float32Bits.canonicalNaN;
      }
      flags.add(FpFlags.divideByZero);
      final sign = (a ^ b) & _Float32Bits.signMask;
      return sign | _Float32Bits.expMask;
    }

    return _roundResult(da / db, flags);
  }

  static int sqrt(int a, RoundingMode rm, FpFlagsAccumulator flags) {
    if (_isSNaN(a)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a)) return _Float32Bits.canonicalNaN;

    final da = _toDouble(a);
    if (da < 0) {
      flags.add(FpFlags.invalidOp);
      return _Float32Bits.canonicalNaN;
    }

    return _roundResult(math.sqrt(da), flags);
  }

  static int fma(
    int a,
    int b,
    int c,
    RoundingMode rm,
    FpFlagsAccumulator flags,
  ) {
    if (_isSNaN(a) || _isSNaN(b) || _isSNaN(c)) {
      flags.add(FpFlags.invalidOp);
    }
    if (_isNaN(a) || _isNaN(b) || _isNaN(c)) return _Float32Bits.canonicalNaN;

    if ((_isInf(a) && _toDouble(b) == 0) ||
        (_isInf(b) && _toDouble(a) == 0)) {
      flags.add(FpFlags.invalidOp);
      return _Float32Bits.canonicalNaN;
    }

    final result = _toDouble(a) * _toDouble(b) + _toDouble(c);
    return _roundResult(result, flags);
  }

  static int classify(int a) {
    final sign = (a & _Float32Bits.signMask) != 0;
    final exp = (a & _Float32Bits.expMask) >> _Float32Bits.expShift;
    final mant = a & _Float32Bits.mantMask;

    if (exp == _Float32Bits.biasedExpMax) {
      if (mant != 0) {
        return (mant & _Float32Bits.qNanBit) != 0
            ? _FClass.quietNaN
            : _FClass.signalingNaN;
      }
      return sign ? _FClass.negInf : _FClass.posInf;
    }

    if (exp == 0) {
      if (mant == 0) return sign ? _FClass.negZero : _FClass.posZero;
      return sign ? _FClass.negSubnormal : _FClass.posSubnormal;
    }

    return sign ? _FClass.negNormal : _FClass.posNormal;
  }

  static bool eq(int a, int b, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) || _isNaN(b)) return false;
    return _toDouble(a) == _toDouble(b);
  }

  static bool lt(int a, int b, FpFlagsAccumulator flags) {
    if (_isNaN(a) || _isNaN(b)) {
      flags.add(FpFlags.invalidOp);
      return false;
    }
    return _toDouble(a) < _toDouble(b);
  }

  static bool le(int a, int b, FpFlagsAccumulator flags) {
    if (_isNaN(a) || _isNaN(b)) {
      flags.add(FpFlags.invalidOp);
      return false;
    }
    return _toDouble(a) <= _toDouble(b);
  }

  static int min(int a, int b, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) && _isNaN(b)) return _Float32Bits.canonicalNaN;
    if (_isNaN(a)) return b;
    if (_isNaN(b)) return a;

    final da = _toDouble(a);
    final db = _toDouble(b);
    if (da == 0 && db == 0) {
      return ((a | b) & _Float32Bits.signMask) != 0 ? (a | b) : (a & b);
    }
    return da < db ? a : b;
  }

  static int max(int a, int b, FpFlagsAccumulator flags) {
    if (_isSNaN(a) || _isSNaN(b)) flags.add(FpFlags.invalidOp);
    if (_isNaN(a) && _isNaN(b)) return _Float32Bits.canonicalNaN;
    if (_isNaN(a)) return b;
    if (_isNaN(b)) return a;

    final da = _toDouble(a);
    final db = _toDouble(b);
    if (da == 0 && db == 0) {
      return ((a & b) & _Float32Bits.signMask) != 0 ? (a & b) : (a | b);
    }
    return da > db ? a : b;
  }

  static int _roundResult(double result, FpFlagsAccumulator flags) {
    if (result.isNaN) {
      flags.add(FpFlags.invalidOp);
      return _Float32Bits.canonicalNaN;
    }
    final bits = _fromDouble(result);
    final reconstructed = _toDouble(bits);
    if (reconstructed != result) {
      if (reconstructed.isInfinite && !result.isInfinite) {
        flags.add(FpFlags.overflow | FpFlags.inexact);
      } else {
        flags.add(FpFlags.inexact);
      }
    }
    return bits;
  }
}

class _Float32Bits {
  static const fullMask = 0xFFFFFFFF;
  static const signMask = 0x80000000;
  static const expMask = 0x7F800000;
  static const mantMask = 0x007FFFFF;
  static const qNanBit = 0x00400000;
  static const expShift = 23;
  static const biasedExpMax = 0xFF;
  static const canonicalNaN = 0x7FC00000;
}

class _FClass {
  static const negInf = 1 << 0;
  static const negNormal = 1 << 1;
  static const negSubnormal = 1 << 2;
  static const negZero = 1 << 3;
  static const posZero = 1 << 4;
  static const posSubnormal = 1 << 5;
  static const posNormal = 1 << 6;
  static const posInf = 1 << 7;
  static const signalingNaN = 1 << 8;
  static const quietNaN = 1 << 9;
}
