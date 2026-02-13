class CExtension {
  const CExtension._();

  static int expand(int compressedInsn) {
    final insn = compressedInsn & _Mask.halfword;
    final quadrant = insn & _Mask.quadrant;
    switch (quadrant) {
      case _Quadrant.q0:
        return _expandQ0(insn);
      case _Quadrant.q1:
        return _expandQ1(insn);
      case _Quadrant.q2:
        return _expandQ2(insn);
      default:
        throw _illegalInsn(insn);
    }
  }

  static bool isCompressed(int insn) =>
      (insn & _Mask.quadrant) != _Quadrant.fullWidth;

  static int _expandQ0(int insn) {
    final funct3 = (insn >> _Shift.cFunct3) & _Mask.funct3;
    final rdPrime = ((insn >> _Shift.cRdQ0) & _Mask.reg3) + _regPrimeBase;
    final rs1Prime =
        ((insn >> _Shift.cRs1Q0) & _Mask.reg3) + _regPrimeBase;

    switch (funct3) {
      case _CQ0Funct.addi4spn:
        final imm = _fieldExtract(insn, 11, 4, 5) |
            _fieldExtract(insn, 7, 6, 9) |
            _fieldExtract(insn, 6, 2, 2) |
            _fieldExtract(insn, 5, 3, 3);
        if (imm == 0) throw _illegalInsn(insn);
        return _encodeI(
          opcode: _Op.opImm,
          rd: rdPrime,
          funct3: _F3.addi,
          rs1: _Reg.sp,
          imm: imm,
        );
      case _CQ0Funct.lw:
        final imm = _fieldExtract(insn, 10, 3, 5) |
            _fieldExtract(insn, 6, 2, 2) |
            _fieldExtract(insn, 5, 6, 6);
        return _encodeI(
          opcode: _Op.load,
          rd: rdPrime,
          funct3: _F3.lw,
          rs1: rs1Prime,
          imm: imm,
        );
      case _CQ0Funct.ld:
        final imm = _fieldExtract(insn, 10, 3, 5) |
            _fieldExtract(insn, 5, 6, 7);
        return _encodeI(
          opcode: _Op.load,
          rd: rdPrime,
          funct3: _F3.ld,
          rs1: rs1Prime,
          imm: imm,
        );
      case _CQ0Funct.sw:
        final imm = _fieldExtract(insn, 10, 3, 5) |
            _fieldExtract(insn, 6, 2, 2) |
            _fieldExtract(insn, 5, 6, 6);
        return _encodeS(
          opcode: _Op.store,
          funct3: _F3.sw,
          rs1: rs1Prime,
          rs2: rdPrime,
          imm: imm,
        );
      case _CQ0Funct.sd:
        final imm = _fieldExtract(insn, 10, 3, 5) |
            _fieldExtract(insn, 5, 6, 7);
        return _encodeS(
          opcode: _Op.store,
          funct3: _F3.sd,
          rs1: rs1Prime,
          rs2: rdPrime,
          imm: imm,
        );
      default:
        throw _illegalInsn(insn);
    }
  }

  static int _expandQ1(int insn) {
    final funct3 = (insn >> _Shift.cFunct3) & _Mask.funct3;
    final rd = (insn >> _Shift.cRdQ12) & _Mask.reg5;

    switch (funct3) {
      case _CQ1Funct.addiNop:
        if (rd == 0) return _nop;
        final imm = _signExtend(
          _fieldExtract(insn, 12, 5, 5) |
              _fieldExtract(insn, 2, 0, 4),
          _ImmBits.ci,
        );
        return _encodeI(
          opcode: _Op.opImm,
          rd: rd,
          funct3: _F3.addi,
          rs1: rd,
          imm: imm,
        );
      case _CQ1Funct.addiw:
        if (rd == 0) throw _illegalInsn(insn);
        final imm = _signExtend(
          _fieldExtract(insn, 12, 5, 5) |
              _fieldExtract(insn, 2, 0, 4),
          _ImmBits.ci,
        );
        return _encodeI(
          opcode: _Op.opImm32,
          rd: rd,
          funct3: _F3.addi,
          rs1: rd,
          imm: imm,
        );
      case _CQ1Funct.li:
        final imm = _signExtend(
          _fieldExtract(insn, 12, 5, 5) |
              _fieldExtract(insn, 2, 0, 4),
          _ImmBits.ci,
        );
        return _encodeI(
          opcode: _Op.opImm,
          rd: rd,
          funct3: _F3.addi,
          rs1: _Reg.zero,
          imm: imm,
        );
      case _CQ1Funct.luiAddi16sp:
        return _expandLuiOrAddi16sp(insn, rd);
      case _CQ1Funct.miscAlu:
        return _expandQ1MiscAlu(insn);
      case _CQ1Funct.j:
        return _expandCJ(insn, _Reg.zero);
      case _CQ1Funct.beqz:
        return _expandCBranch(insn, _F3.beq);
      case _CQ1Funct.bnez:
        return _expandCBranch(insn, _F3.bne);
      default:
        throw _illegalInsn(insn);
    }
  }

  static int _expandLuiOrAddi16sp(int insn, int rd) {
    if (rd == _Reg.sp) {
      final imm = _signExtend(
        _fieldExtract(insn, 12, 9, 9) |
            _fieldExtract(insn, 6, 4, 4) |
            _fieldExtract(insn, 5, 6, 6) |
            _fieldExtract(insn, 3, 7, 8) |
            _fieldExtract(insn, 2, 5, 5),
        _ImmBits.addi16sp,
      );
      if (imm == 0) throw _illegalInsn(insn);
      return _encodeI(
        opcode: _Op.opImm,
        rd: _Reg.sp,
        funct3: _F3.addi,
        rs1: _Reg.sp,
        imm: imm,
      );
    }
    if (rd == 0) throw _illegalInsn(insn);
    final imm = _signExtend(
      _fieldExtract(insn, 12, 17, 17) |
          _fieldExtract(insn, 2, 12, 16),
      _ImmBits.lui,
    );
    return _encodeU(opcode: _Op.lui, rd: rd, imm: imm);
  }

  static int _expandQ1MiscAlu(int insn) {
    final subFunct = (insn >> _Shift.cAluFunct) & _Mask.aluFunct;
    final rdPrime =
        ((insn >> _Shift.cRs1Q0) & _Mask.reg3) + _regPrimeBase;

    switch (subFunct) {
      case _CAluFunct.srli:
        final shamt = _fieldExtract(insn, 12, 5, 5) |
            _fieldExtract(insn, 2, 0, 4);
        return _encodeI(
          opcode: _Op.opImm,
          rd: rdPrime,
          funct3: _F3.srli,
          rs1: rdPrime,
          imm: shamt,
        );
      case _CAluFunct.srai:
        final shamt = _fieldExtract(insn, 12, 5, 5) |
            _fieldExtract(insn, 2, 0, 4);
        return _encodeI(
          opcode: _Op.opImm,
          rd: rdPrime,
          funct3: _F3.srli,
          rs1: rdPrime,
          imm: shamt | _ShamtFlag.arithmetic,
        );
      case _CAluFunct.andi:
        final imm = _signExtend(
          _fieldExtract(insn, 12, 5, 5) |
              _fieldExtract(insn, 2, 0, 4),
          _ImmBits.ci,
        );
        return _encodeI(
          opcode: _Op.opImm,
          rd: rdPrime,
          funct3: _F3.andi,
          rs1: rdPrime,
          imm: imm,
        );
      case _CAluFunct.subXorOrAnd:
        return _expandQ1RegReg(insn, rdPrime);
      default:
        throw _illegalInsn(insn);
    }
  }

  static int _expandQ1RegReg(int insn, int rdPrime) {
    final rs2Prime =
        ((insn >> _Shift.cRdQ0) & _Mask.reg3) + _regPrimeBase;
    final subOp = ((insn >> _Shift.cSubOp5) & _Mask.subOp2) |
        ((insn >> _Shift.cSubOp12To2) & _Mask.subOpBit2);

    switch (subOp) {
      case _CRegRegOp.sub:
        return _encodeR(
          opcode: _Op.op,
          rd: rdPrime,
          funct3: _F3.addSub,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.sub,
        );
      case _CRegRegOp.xor:
        return _encodeR(
          opcode: _Op.op,
          rd: rdPrime,
          funct3: _F3.xor,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.base,
        );
      case _CRegRegOp.or:
        return _encodeR(
          opcode: _Op.op,
          rd: rdPrime,
          funct3: _F3.or,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.base,
        );
      case _CRegRegOp.and:
        return _encodeR(
          opcode: _Op.op,
          rd: rdPrime,
          funct3: _F3.and,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.base,
        );
      case _CRegRegOp.subw:
        return _encodeR(
          opcode: _Op.op32,
          rd: rdPrime,
          funct3: _F3.addSub,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.sub,
        );
      case _CRegRegOp.addw:
        return _encodeR(
          opcode: _Op.op32,
          rd: rdPrime,
          funct3: _F3.addSub,
          rs1: rdPrime,
          rs2: rs2Prime,
          funct7: _F7.base,
        );
      default:
        throw _illegalInsn(insn);
    }
  }

  static int _expandCJ(int insn, int rd) {
    final rawImm = _fieldExtract(insn, 12, 11, 11) |
        _fieldExtract(insn, 11, 4, 4) |
        _fieldExtract(insn, 9, 8, 9) |
        _fieldExtract(insn, 8, 10, 10) |
        _fieldExtract(insn, 7, 6, 6) |
        _fieldExtract(insn, 6, 7, 7) |
        _fieldExtract(insn, 3, 1, 3) |
        _fieldExtract(insn, 2, 5, 5);
    final imm = _signExtend(rawImm, _ImmBits.cj);
    return _encodeJ(opcode: _Op.jal, rd: rd, imm: imm);
  }

  static int _expandCBranch(int insn, int funct3) {
    final rs1Prime =
        ((insn >> _Shift.cRs1Q0) & _Mask.reg3) + _regPrimeBase;
    final rawImm = _fieldExtract(insn, 12, 8, 8) |
        _fieldExtract(insn, 10, 3, 4) |
        _fieldExtract(insn, 5, 6, 7) |
        _fieldExtract(insn, 3, 1, 2) |
        _fieldExtract(insn, 2, 5, 5);
    final imm = _signExtend(rawImm, _ImmBits.cb);
    return _encodeB(
      opcode: _Op.branch,
      funct3: funct3,
      rs1: rs1Prime,
      rs2: _Reg.zero,
      imm: imm,
    );
  }

  static int _expandQ2(int insn) {
    final funct3 = (insn >> _Shift.cFunct3) & _Mask.funct3;
    final rd = (insn >> _Shift.cRdQ12) & _Mask.reg5;
    final rs2 = (insn >> _Shift.cRdQ0) & _Mask.reg5;

    switch (funct3) {
      case _CQ2Funct.slli:
        final shamt = _fieldExtract(insn, 12, 5, 5) | rs2;
        if (rd == 0) return _nop;
        return _encodeI(
          opcode: _Op.opImm,
          rd: rd,
          funct3: _F3.slli,
          rs1: rd,
          imm: shamt,
        );
      case _CQ2Funct.lwsp:
        final imm = _fieldExtract(insn, 12, 5, 5) |
            (rs2 & (_Mask.lwspBits << _Shift.lwspLow)) |
            _fieldExtract(insn, 2, 6, 7);
        if (rd == 0) throw _illegalInsn(insn);
        return _encodeI(
          opcode: _Op.load,
          rd: rd,
          funct3: _F3.lw,
          rs1: _Reg.sp,
          imm: imm,
        );
      case _CQ2Funct.ldsp:
        final imm = _fieldExtract(insn, 12, 5, 5) |
            (rs2 & (_Mask.ldspBits << _Shift.ldspLow)) |
            _fieldExtract(insn, 2, 6, 8);
        if (rd == 0) throw _illegalInsn(insn);
        return _encodeI(
          opcode: _Op.load,
          rd: rd,
          funct3: _F3.ld,
          rs1: _Reg.sp,
          imm: imm,
        );
      case _CQ2Funct.jalrMvAddEbreak:
        return _expandQ2JalrMvAdd(insn, rd, rs2);
      case _CQ2Funct.swsp:
        final imm = _fieldExtract(insn, 9, 2, 5) |
            _fieldExtract(insn, 7, 6, 7);
        return _encodeS(
          opcode: _Op.store,
          funct3: _F3.sw,
          rs1: _Reg.sp,
          rs2: rs2,
          imm: imm,
        );
      case _CQ2Funct.sdsp:
        final imm = _fieldExtract(insn, 10, 3, 5) |
            _fieldExtract(insn, 7, 6, 8);
        return _encodeS(
          opcode: _Op.store,
          funct3: _F3.sd,
          rs1: _Reg.sp,
          rs2: rs2,
          imm: imm,
        );
      default:
        throw _illegalInsn(insn);
    }
  }

  static int _expandQ2JalrMvAdd(int insn, int rd, int rs2) {
    final bit12 = (insn >> _Shift.cBit12) & 1;
    if (bit12 == 0) {
      if (rs2 == 0) {
        if (rd == 0) throw _illegalInsn(insn);
        return _encodeI(
          opcode: _Op.jalr,
          rd: _Reg.zero,
          funct3: _F3.jalr,
          rs1: rd,
          imm: 0,
        );
      }
      return _encodeR(
        opcode: _Op.op,
        rd: rd,
        funct3: _F3.addSub,
        rs1: _Reg.zero,
        rs2: rs2,
        funct7: _F7.base,
      );
    }
    if (rs2 == 0) {
      if (rd == 0) return _ebreak;
      return _encodeI(
        opcode: _Op.jalr,
        rd: _Reg.ra,
        funct3: _F3.jalr,
        rs1: rd,
        imm: 0,
      );
    }
    if (rd == 0) return _nop;
    return _encodeR(
      opcode: _Op.op,
      rd: rd,
      funct3: _F3.addSub,
      rs1: rd,
      rs2: rs2,
      funct7: _F7.base,
    );
  }

  static int _encodeR({
    required int opcode,
    required int rd,
    required int funct3,
    required int rs1,
    required int rs2,
    required int funct7,
  }) =>
      opcode |
      (rd << _EncShift.rd) |
      (funct3 << _EncShift.funct3) |
      (rs1 << _EncShift.rs1) |
      (rs2 << _EncShift.rs2) |
      (funct7 << _EncShift.funct7);

  static int _encodeI({
    required int opcode,
    required int rd,
    required int funct3,
    required int rs1,
    required int imm,
  }) =>
      opcode |
      (rd << _EncShift.rd) |
      (funct3 << _EncShift.funct3) |
      (rs1 << _EncShift.rs1) |
      ((imm & _Mask.imm12) << _EncShift.immI);

  static int _encodeS({
    required int opcode,
    required int funct3,
    required int rs1,
    required int rs2,
    required int imm,
  }) {
    final low = imm & _Mask.reg5;
    final high = (imm >> _EncShift.sImmHighSrc) & _Mask.funct7;
    return opcode |
        (low << _EncShift.rd) |
        (funct3 << _EncShift.funct3) |
        (rs1 << _EncShift.rs1) |
        (rs2 << _EncShift.rs2) |
        (high << _EncShift.funct7);
  }

  static int _encodeB({
    required int opcode,
    required int funct3,
    required int rs1,
    required int rs2,
    required int imm,
  }) {
    final bit11 = (imm >> _BImm.bit11Src) & 1;
    final bits4to1 = (imm >> 1) & 0xF;
    final bits10to5 = (imm >> _BImm.bit5Src) & 0x3F;
    final bit12 = (imm >> _BImm.bit12Src) & 1;
    return opcode |
        (bit11 << _EncShift.rd) |
        (bits4to1 << (_EncShift.rd + 1)) |
        (funct3 << _EncShift.funct3) |
        (rs1 << _EncShift.rs1) |
        (rs2 << _EncShift.rs2) |
        (bits10to5 << _EncShift.funct7) |
        (bit12 << _BImm.bit12Dst);
  }

  static int _encodeU({
    required int opcode,
    required int rd,
    required int imm,
  }) =>
      opcode | (rd << _EncShift.rd) | (imm & _Mask.upperImm);

  static int _encodeJ({
    required int opcode,
    required int rd,
    required int imm,
  }) {
    final bits19to12 = (imm >> _JImm.bit12Src) & 0xFF;
    final bit11 = (imm >> _JImm.bit11Src) & 1;
    final bits10to1 = (imm >> 1) & 0x3FF;
    final bit20 = (imm >> _JImm.bit20Src) & 1;
    return opcode |
        (rd << _EncShift.rd) |
        (bits19to12 << _JImm.bits19to12Dst) |
        (bit11 << _JImm.bit11Dst) |
        (bits10to1 << _JImm.bits10to1Dst) |
        (bit20 << _JImm.bit20Dst);
  }

  static int _fieldExtract(
    int val,
    int srcPos,
    int dstPos,
    int dstPosMax,
  ) {
    final width = dstPosMax - dstPos + 1;
    final mask = ((1 << width) - 1) << dstPos;
    if (dstPos >= srcPos) {
      return (val << (dstPos - srcPos)) & mask;
    }
    return (val >> (srcPos - dstPos)) & mask;
  }

  static int _signExtend(int value, int bits) {
    final signBit = 1 << (bits - 1);
    final mask = (1 << bits) - 1;
    final masked = value & mask;
    return (masked ^ signBit) - signBit;
  }

  static Exception _illegalInsn(int insn) =>
      Exception('Illegal compressed instruction: '
          '0x${insn.toRadixString(16).padLeft(4, '0')}');

  static const _regPrimeBase = 8;
  static const _nop = 0x00000013;
  static const _ebreak = 0x00100073;
}

class _Quadrant {
  static const q0 = 0x00;
  static const q1 = 0x01;
  static const q2 = 0x02;
  static const fullWidth = 0x03;
}

class _Mask {
  static const halfword = 0xFFFF;
  static const quadrant = 0x03;
  static const funct3 = 0x07;
  static const reg3 = 0x07;
  static const reg5 = 0x1F;
  static const funct7 = 0x7F;
  static const imm12 = 0xFFF;
  static const upperImm = 0xFFFFF000;
  static const aluFunct = 0x03;
  static const subOp2 = 0x03;
  static const subOpBit2 = 0x04;
  static const lwspBits = 0x07;
  static const ldspBits = 0x03;
}

class _Shift {
  static const cFunct3 = 13;
  static const cRdQ0 = 2;
  static const cRs1Q0 = 7;
  static const cRdQ12 = 7;
  static const cAluFunct = 10;
  static const cSubOp5 = 5;
  static const cSubOp12To2 = 10;
  static const cBit12 = 12;
  static const lwspLow = 2;
  static const ldspLow = 3;
}

class _EncShift {
  static const rd = 7;
  static const funct3 = 12;
  static const rs1 = 15;
  static const rs2 = 20;
  static const funct7 = 25;
  static const immI = 20;
  static const sImmHighSrc = 5;
}

class _Op {
  static const load = 0x03;
  static const opImm = 0x13;
  static const store = 0x23;
  static const op = 0x33;
  static const lui = 0x37;
  static const op32 = 0x3B;
  static const branch = 0x63;
  static const jalr = 0x67;
  static const jal = 0x6F;
  static const opImm32 = 0x1B;
}

class _F3 {
  static const addi = 0;
  static const slli = 1;
  static const lw = 2;
  static const ld = 3;
  static const xor = 4;
  static const srli = 5;
  static const or = 6;
  static const and = 7;
  static const andi = 7;
  static const sw = 2;
  static const sd = 3;
  static const addSub = 0;
  static const beq = 0;
  static const bne = 1;
  static const jalr = 0;
}

class _F7 {
  static const base = 0x00;
  static const sub = 0x20;
}

class _ShamtFlag {
  static const arithmetic = 1 << 10;
}

class _Reg {
  static const zero = 0;
  static const ra = 1;
  static const sp = 2;
}

class _CQ0Funct {
  static const addi4spn = 0;
  static const lw = 2;
  static const ld = 3;
  static const sw = 6;
  static const sd = 7;
}

class _CQ1Funct {
  static const addiNop = 0;
  static const addiw = 1;
  static const li = 2;
  static const luiAddi16sp = 3;
  static const miscAlu = 4;
  static const j = 5;
  static const beqz = 6;
  static const bnez = 7;
}

class _CQ2Funct {
  static const slli = 0;
  static const lwsp = 2;
  static const ldsp = 3;
  static const jalrMvAddEbreak = 4;
  static const swsp = 6;
  static const sdsp = 7;
}

class _CAluFunct {
  static const srli = 0;
  static const srai = 1;
  static const andi = 2;
  static const subXorOrAnd = 3;
}

class _CRegRegOp {
  static const sub = 0;
  static const xor = 1;
  static const or = 2;
  static const and = 3;
  static const subw = 4;
  static const addw = 5;
}

class _ImmBits {
  static const ci = 6;
  static const addi16sp = 10;
  static const lui = 18;
  static const cj = 12;
  static const cb = 9;
}

class _BImm {
  static const bit11Src = 11;
  static const bit5Src = 5;
  static const bit12Src = 12;
  static const bit12Dst = 31;
}

class _JImm {
  static const bit12Src = 12;
  static const bit11Src = 11;
  static const bit20Src = 20;
  static const bits19to12Dst = 12;
  static const bit11Dst = 20;
  static const bits10to1Dst = 21;
  static const bit20Dst = 31;
}
