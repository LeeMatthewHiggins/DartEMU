class InstructionDecoder {
  const InstructionDecoder._();

  static int extractRd(int insn) => (insn >> _rdShift) & _regMask;

  static int extractRs1(int insn) => (insn >> _rs1Shift) & _regMask;

  static int extractRs2(int insn) => (insn >> _rs2Shift) & _regMask;

  static int extractFunct3(int insn) => (insn >> _funct3Shift) & _funct3Mask;

  static int extractFunct7(int insn) => (insn >> _funct7Shift) & _funct7Mask;

  static int extractImmI(int insn) =>
      _signExtend(insn >> _immIShift, _immIBits);

  static int extractImmS(int insn) {
    final low = (insn >> _rdShift) & _regMask;
    final high = (insn >> _funct7Shift) & _funct7Mask;
    return _signExtend((high << _regBits) | low, _immSBits);
  }

  static int extractImmB(int insn) {
    final bit11 = (insn >> _rdShift) & 1;
    final bits4to1 = (insn >> (_rdShift + 1)) & 0xF;
    final bits10to5 = (insn >> _immBMidShift) & 0x3F;
    final bit12 = (insn >> _immBHighShift) & 1;
    return _signExtend(
      (bit12 << _immBBit12) |
          (bit11 << _immBBit11) |
          (bits10to5 << _immBBit5) |
          (bits4to1 << 1),
      _immBBits,
    );
  }

  static int extractImmJ(int insn) {
    final bits19to12 = (insn >> _immJMidShift) & 0xFF;
    final bit11 = (insn >> _immJBit11Shift) & 1;
    final bits10to1 = (insn >> _immJLowShift) & 0x3FF;
    final bit20 = (insn >> _immJHighShift) & 1;
    return _signExtend(
      (bit20 << _immJBit20) |
          (bits19to12 << _immJBit12) |
          (bit11 << _immJBit11) |
          (bits10to1 << 1),
      _immJBits,
    );
  }

  static bool isCompressed(int insn) =>
      (insn & _compressedMask) != _compressedMask;

  static int _signExtend(int value, int bits) {
    final signBit = 1 << (bits - 1);
    return (value ^ signBit) - signBit;
  }

  static const _regMask = 0x1F;
  static const _regBits = 5;
  static const _rdShift = 7;
  static const _rs1Shift = 15;
  static const _rs2Shift = 20;
  static const _funct3Shift = 12;
  static const _funct3Mask = 0x07;
  static const _funct7Shift = 25;
  static const _funct7Mask = 0x7F;
  static const _immIShift = 20;
  static const _immIBits = 12;
  static const _immSBits = 12;
  static const _immBMidShift = 25;
  static const _immBHighShift = 31;
  static const _immBBit12 = 12;
  static const _immBBit11 = 11;
  static const _immBBit5 = 5;
  static const _immBBits = 13;
  static const _immJMidShift = 12;
  static const _immJBit11Shift = 20;
  static const _immJLowShift = 21;
  static const _immJHighShift = 31;
  static const _immJBit20 = 20;
  static const _immJBit12 = 12;
  static const _immJBit11 = 11;
  static const _immJBits = 21;
  static const _compressedMask = 0x03;
}
