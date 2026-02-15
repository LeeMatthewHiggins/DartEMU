import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/extensions/f_extension.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';
import 'package:dart_emu/src/cpu/softfp/soft_float.dart';
import 'package:dart_emu/src/cpu/softfp/soft_float64.dart';
import 'package:dart_emu/src/util/bit_utils.dart';

class DExtension {
  factory DExtension({required RiscVCpuState state}) =>
      state.isRv32
          ? _DExtension32(state: state)
          : _DExtension64(state: state);

  DExtension._({required this.state});

  final RiscVCpuState state;
  final FpFlagsAccumulator _flags = FpFlagsAccumulator();

  void executeArithmetic(int insn) {
    final funct7 = insn >>> _Shift.funct7;
    final rs2Field = (insn >> _Shift.rs2) & _Mask.reg;
    final rs1 = (insn >> _Shift.rs1) & _Mask.reg;
    final funct3 = (insn >> _Shift.funct3) & _Mask.funct3;
    final rd = (insn >> _Shift.rd) & _Mask.reg;
    final rm = _resolveRm(funct3);

    _flags.reset();

    switch (funct7) {
      case _Funct7.add:
        _writeFp(
          rd,
          SoftFloat64.add(
            _readFp(rs1), _readFp(rs2Field), rm, _flags,
          ),
        );
      case _Funct7.sub:
        _writeFp(
          rd,
          SoftFloat64.sub(
            _readFp(rs1), _readFp(rs2Field), rm, _flags,
          ),
        );
      case _Funct7.mul:
        _writeFp(
          rd,
          SoftFloat64.mul(
            _readFp(rs1), _readFp(rs2Field), rm, _flags,
          ),
        );
      case _Funct7.div:
        _writeFp(
          rd,
          SoftFloat64.div(
            _readFp(rs1), _readFp(rs2Field), rm, _flags,
          ),
        );
      case _Funct7.sqrt:
        _writeFp(
          rd,
          SoftFloat64.sqrt(_readFp(rs1), rm, _flags),
        );
      case _Funct7.sgnj:
        _executeSgnj(rs1, rs2Field, rd, funct3);
      case _Funct7.minMax:
        _executeMinMax(rs1, rs2Field, rd, funct3);
      case _Funct7.cvtWFromD:
        _executeCvtToInt(rs1, rd, rs2Field, rm);
      case _Funct7.cvtDFromW:
        _executeCvtFromInt(rs1, rd, rs2Field);
      case _Funct7.cvtDFromS:
        _executeCvtFromSingle(rs1, rd);
      case _Funct7.cmp:
        _executeCompare(rs1, rs2Field, rd, funct3);
      case _Funct7.mvClassXD:
        if (funct3 == _CmpFunct3.fmvOrClass) {
          _writeIntReg(rd, _readFp(rs1));
        } else {
          _writeIntReg(
            rd,
            SoftFloat64.classify(_readFp(rs1)),
          );
        }
      case _Funct7.mvDX:
        _writeFp(rd, state.regs[rs1]);
      default:
        throw const IllegalFpException();
    }

    _flushFlags();
  }

  void executeFusedMulAdd(int insn, int opcode) {
    final rd = (insn >> _Shift.rd) & _Mask.reg;
    final rs1 = (insn >> _Shift.rs1) & _Mask.reg;
    final rs2 = (insn >> _Shift.rs2) & _Mask.reg;
    final rs3 = insn >>> _Shift.rs3;
    final funct3 =
        (insn >> _Shift.funct3) & _Mask.funct3;
    final rm = _resolveRm(funct3);

    _flags.reset();

    final a = _readFp(rs1);
    final b = _readFp(rs2);
    final c = _readFp(rs3);

    int result;
    switch (opcode) {
      case _FmaOpcode.fmadd:
        result = SoftFloat64.fma(a, b, c, rm, _flags);
      case _FmaOpcode.fmsub:
        result = SoftFloat64.fma(
          a, b, _negateF64(c), rm, _flags,
        );
      case _FmaOpcode.fnmsub:
        result = SoftFloat64.fma(
          _negateF64(a), b, c, rm, _flags,
        );
      case _FmaOpcode.fnmadd:
        result = SoftFloat64.fma(
          _negateF64(a), b, _negateF64(c), rm, _flags,
        );
      default:
        throw const IllegalFpException();
    }

    _writeFp(rd, result);
    _flushFlags();
  }

  int _readFp(int reg) => state.fpRegs[reg];

  void _writeFp(int reg, int bits64) {
    state.fpRegs[reg] = bits64;
    _markFsDirty();
  }

  void _writeIntReg(int rd, int value) {
    if (rd != 0) state.regs[rd] = value;
  }

  void _markFsDirty() {
    state.mstatus =
        (state.mstatus & ~_MstatusFp.fsMask) |
        _MstatusFp.fsDirty;
  }

  void _flushFlags() {
    state.fflags |= _flags.flags;
  }

  RoundingMode _resolveRm(int funct3Rm) {
    final rm =
        funct3Rm == _RmBits.dynamic_ ? state.frm : funct3Rm;
    if (rm > _RmBits.maxValid) {
      throw const IllegalFpException();
    }
    return RoundingMode.fromValue(rm);
  }

  void _executeSgnj(
    int rs1,
    int rs2,
    int rd,
    int funct3,
  ) {
    final src = _readFp(rs1);
    final sign2 = _readFp(rs2) & _Float64.signMask;
    final magnitude = src & ~_Float64.signMask;

    final int result;
    switch (funct3) {
      case _SgnjFunct3.sgnj:
        result = magnitude | sign2;
      case _SgnjFunct3.sgnjn:
        result = magnitude | (sign2 ^ _Float64.signMask);
      case _SgnjFunct3.sgnjx:
        result = src ^ sign2;
      default:
        throw const IllegalFpException();
    }
    _writeFp(rd, result);
  }

  void _executeMinMax(
    int rs1,
    int rs2,
    int rd,
    int funct3,
  ) {
    _flags.reset();
    final a = _readFp(rs1);
    final b = _readFp(rs2);
    switch (funct3) {
      case _MinMaxFunct3.min:
        _writeFp(rd, SoftFloat64.min(a, b, _flags));
      case _MinMaxFunct3.max:
        _writeFp(rd, SoftFloat64.max(a, b, _flags));
      default:
        throw const IllegalFpException();
    }
  }

  void _executeCvtToInt(
    int rs1,
    int rd,
    int rs2Field,
    RoundingMode rm,
  ) {
    final val = _bitsToDouble(_readFp(rs1));
    final int result;

    switch (rs2Field) {
      case _CvtRs2.w:
        result = _clampToI32(val, rm);
      case _CvtRs2.wu:
        result = BitUtils.signExtend32(_clampToU32(val, rm));
      case _CvtRs2.l:
        result = _clampToI64(val, rm);
      case _CvtRs2.lu:
        result = _clampToU64(val, rm);
      default:
        throw const IllegalFpException();
    }

    _writeIntReg(rd, result);
    _markFsDirty();
  }

  void _executeCvtFromInt(int rs1, int rd, int rs2Field) {
    final srcInt = state.regs[rs1];
    double val;

    switch (rs2Field) {
      case _CvtRs2.w:
        val = (srcInt & _Mask.word)
            .toSigned(_Bits.word)
            .toDouble();
      case _CvtRs2.wu:
        val = (srcInt & _Mask.word).toDouble();
      case _CvtRs2.l:
        val = srcInt.toDouble();
      case _CvtRs2.lu:
        val = BigInt.from(srcInt)
            .toUnsigned(_Bits.doubleWord)
            .toDouble();
      default:
        throw const IllegalFpException();
    }

    _writeFp(rd, _doubleToBits(val));
  }

  void _executeCvtFromSingle(int rs1, int rd) {
    final srcBits = state.fpRegs[rs1];
    final int f32Bits;
    if ((srcBits & _NanBox.checkMask) == _NanBox.checkMask) {
      f32Bits = srcBits & _Mask.word;
    } else {
      f32Bits = _NanBox.canonicalNaN;
    }
    final val = _f32ToDouble(f32Bits);
    _writeFp(rd, _doubleToBits(val));
  }

  void _executeCompare(
    int rs1,
    int rs2,
    int rd,
    int funct3,
  ) {
    _flags.reset();
    final a = _readFp(rs1);
    final b = _readFp(rs2);

    final bool result;
    switch (funct3) {
      case _CmpFunct3.fle:
        result = SoftFloat64.le(a, b, _flags);
      case _CmpFunct3.flt:
        result = SoftFloat64.lt(a, b, _flags);
      case _CmpFunct3.feq:
        result = SoftFloat64.eq(a, b, _flags);
      default:
        throw const IllegalFpException();
    }
    _writeIntReg(rd, result ? 1 : 0);
  }

  int _clampToI32(double val, RoundingMode rm) {
    if (val.isNaN) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxI32;
    }
    final rounded = _applyRounding(val, rm);
    if (rounded > _Limits.maxI32.toDouble()) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxI32;
    }
    if (rounded < _Limits.minI32.toDouble()) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.minI32;
    }
    final intVal = rounded.toInt();
    if (intVal.toDouble() != val) {
      _flags.add(FpFlags.inexact);
    }
    return intVal;
  }

  int _clampToU32(double val, RoundingMode rm) {
    if (val.isNaN) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxU32;
    }
    final rounded = _applyRounding(val, rm);
    if (rounded > _Limits.maxU32.toDouble()) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxU32;
    }
    if (rounded < 0) {
      _flags.add(FpFlags.invalidOp);
      return 0;
    }
    final intVal = rounded.toInt();
    if (intVal.toDouble() != val) {
      _flags.add(FpFlags.inexact);
    }
    return intVal & _Mask.word;
  }

  int _clampToI64(double val, RoundingMode rm) {
    if (val.isNaN) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxI64;
    }
    final rounded = _applyRounding(val, rm);
    if (rounded >= _Limits.maxI64.toDouble()) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.maxI64;
    }
    if (rounded <= _Limits.minI64.toDouble()) {
      _flags.add(FpFlags.invalidOp);
      return _Limits.minI64;
    }
    final intVal = rounded.toInt();
    if (intVal.toDouble() != val) {
      _flags.add(FpFlags.inexact);
    }
    return intVal;
  }

  int _clampToU64(double val, RoundingMode rm) {
    if (val.isNaN || val < 0) {
      _flags.add(FpFlags.invalidOp);
      return val.isNaN ? -1 : 0;
    }
    final rounded = _applyRounding(val, rm);
    if (rounded < 0) {
      _flags.add(FpFlags.invalidOp);
      return 0;
    }
    final big = BigInt.from(rounded);
    if (big > _Limits.maxU64Big) {
      _flags.add(FpFlags.invalidOp);
      return -1;
    }
    if (rounded != val) _flags.add(FpFlags.inexact);
    return big.toInt();
  }

  static double _applyRounding(
    double val,
    RoundingMode rm,
  ) {
    return switch (rm) {
      RoundingMode.rne => val.roundToDouble(),
      RoundingMode.rtz => val.truncateToDouble(),
      RoundingMode.rdn => val.floorToDouble(),
      RoundingMode.rup => val.ceilToDouble(),
      RoundingMode.rmm => val >= 0
          ? (val + 0.5).floorToDouble()
          : (val - 0.5).ceilToDouble(),
    };
  }

  static int _negateF64(int bits) => bits ^ _Float64.signMask;

  static double _bitsToDouble(int bits64) {
    _convBuf
      ..setUint32(0, bits64 & _Mask.word, Endian.little)
      ..setUint32(
        _ByteConst.wordBytes,
        (bits64 >>> _ByteConst.wordBits) & _Mask.word,
        Endian.little,
      );
    return _convBuf.getFloat64(0, Endian.little);
  }

  static int _doubleToBits(double val) {
    _convBuf.setFloat64(0, val, Endian.little);
    final lo = _convBuf.getUint32(0, Endian.little);
    final hi = _convBuf.getUint32(_ByteConst.wordBytes, Endian.little);
    return lo | (hi << _ByteConst.wordBits);
  }

  static double _f32ToDouble(int bits32) {
    _convBuf.setUint32(0, bits32 & _Mask.word, Endian.little);
    return _convBuf.getFloat32(0, Endian.little);
  }

  static final ByteData _convBuf = ByteData(8);
}

class _DExtension64 extends DExtension {
  _DExtension64({required super.state}) : super._();
}

class _DExtension32 extends DExtension {
  _DExtension32({required super.state}) : super._();

  @override
  void executeArithmetic(int insn) {
    final funct7 = insn >>> _Shift.funct7;
    final funct3 = (insn >> _Shift.funct3) & _Mask.funct3;
    if (funct7 == _Funct7.mvClassXD &&
        funct3 == _CmpFunct3.fmvOrClass) {
      throw const IllegalFpException();
    }
    if (funct7 == _Funct7.mvDX) {
      throw const IllegalFpException();
    }
    super.executeArithmetic(insn);
  }

  @override
  void _executeCvtToInt(
    int rs1,
    int rd,
    int rs2Field,
    RoundingMode rm,
  ) {
    if (rs2Field >= _CvtRs2.l) throw const IllegalFpException();
    super._executeCvtToInt(rs1, rd, rs2Field, rm);
  }

  @override
  void _executeCvtFromInt(int rs1, int rd, int rs2Field) {
    if (rs2Field >= _CvtRs2.l) throw const IllegalFpException();
    super._executeCvtFromInt(rs1, rd, rs2Field);
  }
}

class _Funct7 {
  static const add = 0x01;
  static const sub = 0x05;
  static const mul = 0x09;
  static const div = 0x0D;
  static const sqrt = 0x2D;
  static const sgnj = 0x11;
  static const minMax = 0x15;
  static const cvtWFromD = 0x61;
  static const cvtDFromW = 0x69;
  static const cvtDFromS = 0x21;
  static const cmp = 0x51;
  static const mvClassXD = 0x71;
  static const mvDX = 0x79;
}

class _FmaOpcode {
  static const fmadd = 0x43;
  static const fmsub = 0x47;
  static const fnmsub = 0x4B;
  static const fnmadd = 0x4F;
}

class _SgnjFunct3 {
  static const sgnj = 0;
  static const sgnjn = 1;
  static const sgnjx = 2;
}

class _MinMaxFunct3 {
  static const min = 0;
  static const max = 1;
}

class _CmpFunct3 {
  static const fle = 0;
  static const flt = 1;
  static const feq = 2;
  static const fmvOrClass = 0;
}

class _CvtRs2 {
  static const w = 0;
  static const wu = 1;
  static const l = 2;
  static const lu = 3;
}

class _Shift {
  static const rd = 7;
  static const funct3 = 12;
  static const rs1 = 15;
  static const rs2 = 20;
  static const funct7 = 25;
  static const rs3 = 27;
}

class _Mask {
  static const reg = 0x1F;
  static const funct3 = 0x07;
  static const word = 0xFFFFFFFF;
}

class _NanBox {
  static const checkMask = Int64Const.nanBoxMask;
  static const canonicalNaN = 0x7FC00000;
}

class _Float64 {
  static const signMask = Int64Const.signBit;
}

class _MstatusFp {
  static const fsMask = 0x6000;
  static const fsDirty = 0x6000;
}

class _RmBits {
  static const dynamic_ = 7;
  static const maxValid = 4;
}

class _Limits {
  static const maxI32 = 0x7FFFFFFF;
  static const minI32 = -0x80000000;
  static const maxU32 = 0xFFFFFFFF;
  static const maxI64 = Int64Const.maxSigned;
  static const minI64 = Int64Const.minSigned;
  static final maxU64Big = BigInt.from(1) << 64;
}

class _Bits {
  static const word = 32;
  static const doubleWord = 64;
}

class _ByteConst {
  static const wordBits = 32;
  static const wordBytes = 4;
}
