import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';
import 'package:dart_emu/src/cpu/softfp/soft_float.dart';
import 'package:dart_emu/src/cpu/softfp/soft_float32.dart';
import 'package:dart_emu/src/util/bit_utils.dart';

class FExtension {
  factory FExtension({required RiscVCpuState state}) =>
      state.isRv32 ? _FExtension32(state: state) : _FExtension64(state: state);

  FExtension._({required this.state});

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
          SoftFloat32.add(_readFp(rs1), _readFp(rs2Field), rm, _flags),
        );
      case _Funct7.sub:
        _writeFp(
          rd,
          SoftFloat32.sub(_readFp(rs1), _readFp(rs2Field), rm, _flags),
        );
      case _Funct7.mul:
        _writeFp(
          rd,
          SoftFloat32.mul(_readFp(rs1), _readFp(rs2Field), rm, _flags),
        );
      case _Funct7.div:
        _writeFp(
          rd,
          SoftFloat32.div(_readFp(rs1), _readFp(rs2Field), rm, _flags),
        );
      case _Funct7.sqrt:
        _writeFp(rd, SoftFloat32.sqrt(_readFp(rs1), rm, _flags));
      case _Funct7.sgnj:
        _executeSgnj(rs1, rs2Field, rd, funct3);
      case _Funct7.minMax:
        _executeMinMax(rs1, rs2Field, rd, funct3);
      case _Funct7.cvtWFromS:
        _executeCvtToInt(rs1, rd, rs2Field, rm);
      case _Funct7.cvtSFromW:
        _executeCvtFromInt(rs1, rd, rs2Field, rm);
      case _Funct7.cvtSFromD:
        _executeCvtFromDouble(rs1, rd, rm);
      case _Funct7.cmp:
        _executeCompare(rs1, rs2Field, rd, funct3);
      case _Funct7.mvClassXW:
        if (funct3 == _CmpFunct3.fmvOrClass) {
          _writeIntReg(rd, BitUtils.signExtend32(_readFp(rs1)));
        } else {
          _writeIntReg(rd, SoftFloat32.classify(_readFp(rs1)));
        }
      case _Funct7.mvWX:
        _writeFp(rd, state.regs[rs1] & _Mask.word);
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
    final funct3 = (insn >> _Shift.funct3) & _Mask.funct3;
    final rm = _resolveRm(funct3);

    _flags.reset();

    final a = _readFp(rs1);
    final b = _readFp(rs2);
    final c = _readFp(rs3);

    int result;
    switch (opcode) {
      case _FmaOpcode.fmadd:
        result = SoftFloat32.fma(a, b, c, rm, _flags);
      case _FmaOpcode.fmsub:
        result = SoftFloat32.fma(a, b, _negateF32(c), rm, _flags);
      case _FmaOpcode.fnmsub:
        result = SoftFloat32.fma(_negateF32(a), b, c, rm, _flags);
      case _FmaOpcode.fnmadd:
        result = SoftFloat32.fma(_negateF32(a), b, _negateF32(c), rm, _flags);
      default:
        throw const IllegalFpException();
    }

    _writeFp(rd, result);
    _flushFlags();
  }

  int _readFp(int reg) => state.fpRegs.readNanUnboxed(reg);

  void _writeFp(int reg, int bits32) {
    state.fpRegs.writeWithNanBox(reg, bits32 & _Mask.word);
    _markFsDirty();
  }

  void _writeIntReg(int rd, int value) {
    if (rd != 0) state.regs[rd] = value;
  }

  void _markFsDirty() {
    state.mstatus = (state.mstatus & ~_MstatusFp.fsMask) | _MstatusFp.fsDirty;
  }

  void _flushFlags() {
    state.fflags |= _flags.flags;
  }

  RoundingMode _resolveRm(int funct3Rm) {
    final rm = funct3Rm == _RmBits.dynamic_ ? state.frm : funct3Rm;
    if (rm > _RmBits.maxValid) throw const IllegalFpException();
    return RoundingMode.fromValue(rm);
  }

  void _executeSgnj(int rs1, int rs2, int rd, int funct3) {
    final src = _readFp(rs1);
    final sign2 = _readFp(rs2) & _Float32.signMask;
    final magnitude = src & ~_Float32.signMask;

    final int result;
    switch (funct3) {
      case _SgnjFunct3.sgnj:
        result = magnitude | sign2;
      case _SgnjFunct3.sgnjn:
        result = magnitude | (sign2 ^ _Float32.signMask);
      case _SgnjFunct3.sgnjx:
        result = src ^ sign2;
      default:
        throw const IllegalFpException();
    }
    _writeFp(rd, result);
  }

  void _executeMinMax(int rs1, int rs2, int rd, int funct3) {
    _flags.reset();
    final a = _readFp(rs1);
    final b = _readFp(rs2);
    switch (funct3) {
      case _MinMaxFunct3.min:
        _writeFp(rd, SoftFloat32.min(a, b, _flags));
      case _MinMaxFunct3.max:
        _writeFp(rd, SoftFloat32.max(a, b, _flags));
      default:
        throw const IllegalFpException();
    }
  }

  void _executeCvtToInt(int rs1, int rd, int rs2Field, RoundingMode rm) {
    final src = _readFp(rs1);
    final val = _f32ToDouble(src);
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

  void _executeCvtFromInt(int rs1, int rd, int rs2Field, RoundingMode rm) {
    final srcInt = state.regs[rs1];
    double val;

    switch (rs2Field) {
      case _CvtRs2.w:
        val = (srcInt & _Mask.word).toSigned(_Bits.word).toDouble();
      case _CvtRs2.wu:
        val = (srcInt & _Mask.word).toDouble();
      case _CvtRs2.l:
        val = srcInt.toDouble();
      case _CvtRs2.lu:
        val = BigInt.from(srcInt).toUnsigned(_Bits.doubleWord).toDouble();
      default:
        throw const IllegalFpException();
    }

    _writeFp(rd, _doubleToF32(val));
  }

  void _executeCvtFromDouble(int rs1, int rd, RoundingMode rm) {
    final val = state.fpRegs.readDouble(rs1);
    _writeFp(rd, _doubleToF32(val));
  }

  void _executeCompare(int rs1, int rs2, int rd, int funct3) {
    _flags.reset();
    final a = _readFp(rs1);
    final b = _readFp(rs2);

    final bool result;
    switch (funct3) {
      case _CmpFunct3.fle:
        result = SoftFloat32.le(a, b, _flags);
      case _CmpFunct3.flt:
        result = SoftFloat32.lt(a, b, _flags);
      case _CmpFunct3.feq:
        result = SoftFloat32.eq(a, b, _flags);
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
    if (intVal.toDouble() != val) _flags.add(FpFlags.inexact);
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
    if (intVal.toDouble() != val) _flags.add(FpFlags.inexact);
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
    if (intVal.toDouble() != val) _flags.add(FpFlags.inexact);
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

  static double _applyRounding(double val, RoundingMode rm) {
    return switch (rm) {
      RoundingMode.rne => val.roundToDouble(),
      RoundingMode.rtz => val.truncateToDouble(),
      RoundingMode.rdn => val.floorToDouble(),
      RoundingMode.rup => val.ceilToDouble(),
      RoundingMode.rmm =>
        val >= 0 ? (val + 0.5).floorToDouble() : (val - 0.5).ceilToDouble(),
    };
  }

  static int _negateF32(int bits) => bits ^ _Float32.signMask;

  static double _f32ToDouble(int bits32) {
    _convBuf.setUint32(0, bits32 & _Mask.word, Endian.little);
    return _convBuf.getFloat32(0, Endian.little);
  }

  static int _doubleToF32(double val) {
    _convBuf.setFloat32(0, val, Endian.little);
    return _convBuf.getUint32(0, Endian.little);
  }

  static final ByteData _convBuf = ByteData(8);
}

class _FExtension64 extends FExtension {
  _FExtension64({required super.state}) : super._();
}

class _FExtension32 extends FExtension {
  _FExtension32({required super.state}) : super._();

  @override
  void _executeCvtToInt(int rs1, int rd, int rs2Field, RoundingMode rm) {
    if (rs2Field >= _CvtRs2.l) throw const IllegalFpException();
    super._executeCvtToInt(rs1, rd, rs2Field, rm);
  }

  @override
  void _executeCvtFromInt(int rs1, int rd, int rs2Field, RoundingMode rm) {
    if (rs2Field >= _CvtRs2.l) throw const IllegalFpException();
    super._executeCvtFromInt(rs1, rd, rs2Field, rm);
  }
}

class IllegalFpException implements Exception {
  const IllegalFpException();
}

class _Funct7 {
  static const add = 0x00;
  static const sub = 0x04;
  static const mul = 0x08;
  static const div = 0x0C;
  static const sqrt = 0x2C;
  static const sgnj = 0x10;
  static const minMax = 0x14;
  static const cvtWFromS = 0x60;
  static const cvtSFromW = 0x68;
  static const cvtSFromD = 0x20;
  static const cmp = 0x50;
  static const mvClassXW = 0x70;
  static const mvWX = 0x78;
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

class _Float32 {
  static const signMask = 0x80000000;
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
