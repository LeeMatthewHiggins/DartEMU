import 'dart:typed_data';

import 'package:dart_emu/src/cpu/decoder.dart';
import 'package:dart_emu/src/cpu/tlb.dart';

/// Micro-op identifiers for predecoded instructions.
///
/// Ops with a register destination are only emitted when `rd != 0`;
/// writes to `x0` decode to [nop] (or a non-linking jump), so dispatch
/// never needs an `rd != 0` check. Everything not covered by a
/// dedicated op decodes to [fallback], which re-executes the raw
/// instruction through the classic interpreter path.
class PredecodeOp {
  static const undecoded = 0;
  static const fallback = 1;
  static const nop = 2;

  static const lui = 3;
  static const auipc = 4;

  static const addi = 5;
  static const slti = 6;
  static const sltiu = 7;
  static const xori = 8;
  static const ori = 9;
  static const andi = 10;
  static const slli = 11;
  static const srli = 12;
  static const srai = 13;
  static const addiw = 14;
  static const slliw = 15;
  static const srliw = 16;
  static const sraiw = 17;

  static const add = 18;
  static const sub = 19;
  static const sll = 20;
  static const slt = 21;
  static const sltu = 22;
  static const xor = 23;
  static const srl = 24;
  static const sra = 25;
  static const or = 26;
  static const and = 27;
  static const addw = 28;
  static const subw = 29;
  static const sllw = 30;
  static const srlw = 31;
  static const sraw = 32;

  static const mulDiv = 33;
  static const mulDivW = 34;

  static const jal = 35;
  static const j = 36;
  static const jalr = 37;
  static const jr = 38;

  static const beq = 39;
  static const bne = 40;
  static const blt = 41;
  static const bge = 42;
  static const bltu = 43;
  static const bgeu = 44;

  static const lb = 45;
  static const lh = 46;
  static const lw = 47;
  static const ld = 48;
  static const lbu = 49;
  static const lhu = 50;
  static const lwu = 51;

  static const sb = 52;
  static const sh = 53;
  static const sw = 54;
  static const sd = 55;
}

/// Lazily decoded micro-ops for one physical 4 KiB page of guest RAM.
///
/// One slot per halfword offset; a slot decodes on first execution.
/// Decoding at every halfword offset is always correct: a slot's
/// micro-op is "what would execute if pc pointed here".
class DecodedPage {
  DecodedPage(this.source, this.sourceOffset);

  /// Backing bytes of the RAM range containing this page.
  final ByteData source;

  /// Byte offset of the page within [source].
  final int sourceOffset;

  /// Packed micro-op words: see [PredecodeMeta] for the field layout.
  final Int32List meta = Int32List(slotCount);
  final Int32List imm = Int32List(slotCount);

  static const int slotCount = TlbConstants.pageSize ~/ 2;
}

/// Direct-mapped cache of [DecodedPage]s keyed by physical page.
///
/// Keying by physical location (backing buffer + offset) lets decoded
/// pages survive address-space switches; only `fence.i` — the
/// architectural contract for modified code — invalidates entries.
class PredecodeCache {
  final List<DecodedPage?> _pages = List.filled(_entryCount, null);

  /// Returns the cached decoded page for ([source], [sourceOffset]),
  /// or `null` if not cached.
  DecodedPage? lookup(ByteData source, int sourceOffset) {
    final index = (sourceOffset >>> TlbConstants.pageSizeLog2) & _indexMask;
    final existing = _pages[index];
    if (existing != null &&
        existing.sourceOffset == sourceOffset &&
        identical(existing.source, source)) {
      return existing;
    }
    return null;
  }

  /// Creates a fresh decoded page for ([source], [sourceOffset]),
  /// replacing any conflicting entry.
  DecodedPage insert(ByteData source, int sourceOffset) {
    final index = (sourceOffset >>> TlbConstants.pageSizeLog2) & _indexMask;
    final page = DecodedPage(source, sourceOffset);
    _pages[index] = page;
    return page;
  }

  /// Drops every decoded page (guest executed `fence.i`).
  void invalidateAll() {
    for (var i = 0; i < _pages.length; i++) {
      _pages[i] = null;
    }
  }

  /// Drops the decoded page for ([source], [sourceOffset]) if cached.
  ///
  /// Called when the underlying bytes are written (CPU store or DMA),
  /// so cached decodes stay correct even for guests that skip
  /// `fence.i`. Returns whether an entry was dropped.
  bool invalidatePage(ByteData source, int sourceOffset) {
    final index = (sourceOffset >>> TlbConstants.pageSizeLog2) & _indexMask;
    final existing = _pages[index];
    if (existing != null &&
        existing.sourceOffset == sourceOffset &&
        identical(existing.source, source)) {
      _pages[index] = null;
      return true;
    }
    return false;
  }

  static const _entryCount = 256;
  static const int _indexMask = _entryCount - 1;
}

/// Field layout of a packed micro-op word in [DecodedPage.meta].
///
/// op occupies the low byte so `meta & opMask` is the dispatch key;
/// an undecoded slot is all zeroes. The size bit selects between a
/// 2-byte and a 4-byte instruction: `2 << ((meta >>> sizeShift) & 1)`.
class PredecodeMeta {
  static const opMask = 0xFF;
  static const rdShift = 8;
  static const rs1Shift = 13;
  static const rs2Shift = 18;
  static const sizeShift = 23;
  static const regMask = 0x1F;
}

/// Decodes RV64 instructions (including compressed) into micro-ops.
class Rv64Predecoder {
  /// Decodes the instruction at [slot] of [page] and stores the result.
  ///
  /// Returns the stored op. A 4-byte instruction whose bytes cross the
  /// page boundary decodes to [PredecodeOp.fallback].
  static int decodeSlot(DecodedPage page, int slot) {
    final byteOffset = page.sourceOffset + slot * 2;
    final low = page.source.getUint16(byteOffset, Endian.little);

    if ((low & _compressedMask) != _compressedMask) {
      _decodeCompressed(page, slot, low);
      return page.meta[slot];
    }

    if (slot == DecodedPage.slotCount - 1) {
      _fallback(page, slot, 4);
      return page.meta[slot];
    }

    final insn =
        low | (page.source.getUint16(byteOffset + 2, Endian.little) << 16);
    _decodeFull(page, slot, insn);
    return page.meta[slot];
  }

  static void _store(
    DecodedPage page,
    int slot,
    int op,
    int size, {
    int rd = 0,
    int rs1 = 0,
    int rs2 = 0,
    int imm = 0,
  }) {
    page.imm[slot] = imm;
    page.meta[slot] =
        op |
        (rd << PredecodeMeta.rdShift) |
        (rs1 << PredecodeMeta.rs1Shift) |
        (rs2 << PredecodeMeta.rs2Shift) |
        ((size == 4 ? 1 : 0) << PredecodeMeta.sizeShift);
  }

  static void _fallback(DecodedPage page, int slot, int size) {
    _store(page, slot, PredecodeOp.fallback, size);
  }

  static void _decodeFull(DecodedPage page, int slot, int insn) {
    final opcode = insn & 0x7F;
    final rd = (insn >> 7) & 0x1F;
    final rs1 = (insn >> 15) & 0x1F;
    final rs2 = (insn >> 20) & 0x1F;
    final funct3 = (insn >> 12) & 0x7;
    final funct7 = insn >>> 25;

    switch (opcode) {
      case _Opcode.lui:
        if (rd == 0) return _nop(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.lui,
          4,
          rd: rd,
          imm: (insn & 0xFFFFF000).toSigned(32),
        );

      case _Opcode.auipc:
        if (rd == 0) return _nop(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.auipc,
          4,
          rd: rd,
          imm: (insn & 0xFFFFF000).toSigned(32),
        );

      case _Opcode.jal:
        final imm = InstructionDecoder.extractImmJ(insn);
        if (rd == 0) {
          return _store(page, slot, PredecodeOp.j, 4, imm: imm);
        }
        return _store(page, slot, PredecodeOp.jal, 4, rd: rd, imm: imm);

      case _Opcode.jalr:
        if (funct3 != 0) return _fallback(page, slot, 4);
        final imm = InstructionDecoder.extractImmI(insn);
        if (rd == 0) {
          return _store(page, slot, PredecodeOp.jr, 4, rs1: rs1, imm: imm);
        }
        return _store(
          page,
          slot,
          PredecodeOp.jalr,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );

      case _Opcode.branch:
        const branchOps = [
          PredecodeOp.beq,
          PredecodeOp.bne,
          -1,
          -1,
          PredecodeOp.blt,
          PredecodeOp.bge,
          PredecodeOp.bltu,
          PredecodeOp.bgeu,
        ];
        final branchOp = branchOps[funct3];
        if (branchOp < 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          branchOp,
          4,
          rs1: rs1,
          rs2: rs2,
          imm: InstructionDecoder.extractImmB(insn),
        );

      case _Opcode.load:
        if (rd == 0 || funct3 > 6) return _fallback(page, slot, 4);
        const loadOps = [
          PredecodeOp.lb,
          PredecodeOp.lh,
          PredecodeOp.lw,
          PredecodeOp.ld,
          PredecodeOp.lbu,
          PredecodeOp.lhu,
          PredecodeOp.lwu,
        ];
        return _store(
          page,
          slot,
          loadOps[funct3],
          4,
          rd: rd,
          rs1: rs1,
          imm: InstructionDecoder.extractImmI(insn),
        );

      case _Opcode.store:
        if (funct3 > 3) return _fallback(page, slot, 4);
        const storeOps = [
          PredecodeOp.sb,
          PredecodeOp.sh,
          PredecodeOp.sw,
          PredecodeOp.sd,
        ];
        return _store(
          page,
          slot,
          storeOps[funct3],
          4,
          rs1: rs1,
          rs2: rs2,
          imm: InstructionDecoder.extractImmS(insn),
        );

      case _Opcode.opImm:
        return _decodeOpImm(page, slot, insn, rd, rs1, funct3);

      case _Opcode.opImm32:
        return _decodeOpImm32(page, slot, insn, rd, rs1, funct3);

      case _Opcode.op:
        if (funct7 == 1) {
          if (rd == 0) return _fallback(page, slot, 4);
          return _store(
            page,
            slot,
            PredecodeOp.mulDiv,
            4,
            rd: rd,
            rs1: rs1,
            rs2: rs2,
            imm: funct3,
          );
        }
        return _decodeOpReg(page, slot, insn, rd, rs1, rs2, funct3, funct7);

      case _Opcode.op32:
        if (funct7 == 1) {
          if (rd == 0) return _fallback(page, slot, 4);
          return _store(
            page,
            slot,
            PredecodeOp.mulDivW,
            4,
            rd: rd,
            rs1: rs1,
            rs2: rs2,
            imm: funct3,
          );
        }
        return _decodeOpReg32(page, slot, insn, rd, rs1, rs2, funct3, funct7);

      default:
        return _fallback(page, slot, 4);
    }
  }

  static void _nop(DecodedPage page, int slot, int size) {
    _store(page, slot, PredecodeOp.nop, size);
  }

  static void _decodeOpImm(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int funct3,
  ) {
    if (rd == 0) return _nop(page, slot, 4);
    final imm = InstructionDecoder.extractImmI(insn);
    switch (funct3) {
      case 0:
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 1:
        if ((imm & ~63) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.slli,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 63,
        );
      case 2:
        return _store(
          page,
          slot,
          PredecodeOp.slti,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 3:
        return _store(
          page,
          slot,
          PredecodeOp.sltiu,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 4:
        return _store(
          page,
          slot,
          PredecodeOp.xori,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 5:
        final isArith = (imm & 0x400) != 0;
        if ((imm & ~(63 | 0x400)) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          isArith ? PredecodeOp.srai : PredecodeOp.srli,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 63,
        );
      case 6:
        return _store(
          page,
          slot,
          PredecodeOp.ori,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 7:
        return _store(
          page,
          slot,
          PredecodeOp.andi,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
    }
    return _fallback(page, slot, 4);
  }

  static void _decodeOpImm32(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int funct3,
  ) {
    if (rd == 0) return _nop(page, slot, 4);
    final imm = InstructionDecoder.extractImmI(insn);
    switch (funct3) {
      case 0:
        return _store(
          page,
          slot,
          PredecodeOp.addiw,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 1:
        if ((imm & ~31) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.slliw,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 31,
        );
      case 5:
        final isArith = (imm & 0x400) != 0;
        if ((imm & ~(31 | 0x400)) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          isArith ? PredecodeOp.sraiw : PredecodeOp.srliw,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 31,
        );
    }
    return _fallback(page, slot, 4);
  }

  static void _decodeOpReg(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int rs2,
    int funct3,
    int funct7,
  ) {
    if ((funct7 & ~0x20) != 0) return _fallback(page, slot, 4);
    if (rd == 0) return _nop(page, slot, 4);
    final alt = funct7 == 0x20;
    final regOp = switch ((funct3, alt)) {
      (0, false) => PredecodeOp.add,
      (0, true) => PredecodeOp.sub,
      (1, false) => PredecodeOp.sll,
      (2, false) => PredecodeOp.slt,
      (3, false) => PredecodeOp.sltu,
      (4, false) => PredecodeOp.xor,
      (5, false) => PredecodeOp.srl,
      (5, true) => PredecodeOp.sra,
      (6, false) => PredecodeOp.or,
      (7, false) => PredecodeOp.and,
      _ => -1,
    };
    if (regOp < 0) return _fallback(page, slot, 4);
    _store(page, slot, regOp, 4, rd: rd, rs1: rs1, rs2: rs2);
  }

  static void _decodeOpReg32(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int rs2,
    int funct3,
    int funct7,
  ) {
    if ((funct7 & ~0x20) != 0) return _fallback(page, slot, 4);
    if (rd == 0) return _nop(page, slot, 4);
    final alt = funct7 == 0x20;
    final regOp = switch ((funct3, alt)) {
      (0, false) => PredecodeOp.addw,
      (0, true) => PredecodeOp.subw,
      (1, false) => PredecodeOp.sllw,
      (5, false) => PredecodeOp.srlw,
      (5, true) => PredecodeOp.sraw,
      _ => -1,
    };
    if (regOp < 0) return _fallback(page, slot, 4);
    _store(page, slot, regOp, 4, rd: rd, rs1: rs1, rs2: rs2);
  }

  static void _decodeCompressed(DecodedPage page, int slot, int insn) {
    final quadrant = insn & _compressedMask;
    final funct3 = (insn >> 13) & 0x7;

    switch (quadrant) {
      case 0:
        return _decodeCompressedQ0(page, slot, insn, funct3);
      case 1:
        return _decodeCompressedQ1(page, slot, insn, funct3);
      case 2:
        return _decodeCompressedQ2(page, slot, insn, funct3);
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ0(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rdPrime = ((insn >> 2) & 7) | 8;
    final rs1Prime = ((insn >> 7) & 7) | 8;

    switch (funct3) {
      case 0:
        final imm =
            _cdField(insn, 11, 4, 5) |
            _cdField(insn, 7, 6, 9) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 3, 3);
        if (imm == 0) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          2,
          rd: rdPrime,
          rs1: 2,
          imm: imm,
        );
      case 2:
        final imm =
            _cdField(insn, 10, 3, 5) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 6, 6);
        return _store(
          page,
          slot,
          PredecodeOp.lw,
          2,
          rd: rdPrime,
          rs1: rs1Prime,
          imm: imm,
        );
      case 3:
        final imm = _cdField(insn, 10, 3, 5) | _cdField(insn, 5, 6, 7);
        return _store(
          page,
          slot,
          PredecodeOp.ld,
          2,
          rd: rdPrime,
          rs1: rs1Prime,
          imm: imm,
        );
      case 6:
        final imm =
            _cdField(insn, 10, 3, 5) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 6, 6);
        return _store(
          page,
          slot,
          PredecodeOp.sw,
          2,
          rs1: rs1Prime,
          rs2: rdPrime,
          imm: imm,
        );
      case 7:
        final imm = _cdField(insn, 10, 3, 5) | _cdField(insn, 5, 6, 7);
        return _store(
          page,
          slot,
          PredecodeOp.sd,
          2,
          rs1: rs1Prime,
          rs2: rdPrime,
          imm: imm,
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ1(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rd = (insn >> 7) & 0x1F;

    switch (funct3) {
      case 0:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 1:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(
          page,
          slot,
          PredecodeOp.addiw,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 2:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(page, slot, PredecodeOp.addi, 2, rd: rd, imm: imm);
      case 3:
        if (rd == 2) {
          final imm = _cdSignExtend(
            _cdField(insn, 12, 9, 9) |
                _cdField(insn, 6, 4, 4) |
                _cdField(insn, 5, 6, 6) |
                _cdField(insn, 3, 7, 8) |
                _cdField(insn, 2, 5, 5),
            10,
          );
          if (imm == 0) return _fallback(page, slot, 2);
          return _store(
            page,
            slot,
            PredecodeOp.addi,
            2,
            rd: 2,
            rs1: 2,
            imm: imm,
          );
        }
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 17, 17) | _cdField(insn, 2, 12, 16),
          18,
        );
        return _store(page, slot, PredecodeOp.lui, 2, rd: rd, imm: imm);
      case 4:
        return _decodeCompressedArith(page, slot, insn);
      case 5:
        return _store(page, slot, PredecodeOp.j, 2, imm: _cdJImm(insn));
      case 6:
        final rs1Prime = ((insn >> 7) & 7) | 8;
        return _store(
          page,
          slot,
          PredecodeOp.beq,
          2,
          rs1: rs1Prime,
          imm: _cdBranchImm(insn),
        );
      case 7:
        final rs1Prime = ((insn >> 7) & 7) | 8;
        return _store(
          page,
          slot,
          PredecodeOp.bne,
          2,
          rs1: rs1Prime,
          imm: _cdBranchImm(insn),
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedArith(DecodedPage page, int slot, int insn) {
    final subFunct = (insn >> 10) & 3;
    final rd = ((insn >> 7) & 7) | 8;

    switch (subFunct) {
      case 0:
      case 1:
        final imm = _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4);
        return _store(
          page,
          slot,
          subFunct == 0 ? PredecodeOp.srli : PredecodeOp.srai,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 2:
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(
          page,
          slot,
          PredecodeOp.andi,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 3:
        final rs2 = ((insn >> 2) & 7) | 8;
        final subOp = ((insn >> 5) & 3) | ((insn >> 10) & 4);
        const arithOps = [
          PredecodeOp.sub,
          PredecodeOp.xor,
          PredecodeOp.or,
          PredecodeOp.and,
          PredecodeOp.subw,
          PredecodeOp.addw,
        ];
        if (subOp >= arithOps.length) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          arithOps[subOp],
          2,
          rd: rd,
          rs1: rd,
          rs2: rs2,
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ2(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rd = (insn >> 7) & 0x1F;
    final rs2 = (insn >> 2) & 0x1F;

    switch (funct3) {
      case 0:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdField(insn, 12, 5, 5) | rs2;
        return _store(
          page,
          slot,
          PredecodeOp.slli,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 2:
        if (rd == 0) return _fallback(page, slot, 2);
        final imm =
            _cdField(insn, 12, 5, 5) |
            (rs2 & (7 << 2)) |
            _cdField(insn, 2, 6, 7);
        return _store(page, slot, PredecodeOp.lw, 2, rd: rd, rs1: 2, imm: imm);
      case 3:
        if (rd == 0) return _fallback(page, slot, 2);
        final imm =
            _cdField(insn, 12, 5, 5) |
            (rs2 & (3 << 3)) |
            _cdField(insn, 2, 6, 8);
        return _store(page, slot, PredecodeOp.ld, 2, rd: rd, rs1: 2, imm: imm);
      case 4:
        final bit12 = (insn >> 12) & 1;
        if (bit12 == 0) {
          if (rs2 == 0) {
            if (rd == 0) return _fallback(page, slot, 2);
            return _store(page, slot, PredecodeOp.jr, 2, rs1: rd);
          }
          if (rd == 0) return _nop(page, slot, 2);
          return _store(page, slot, PredecodeOp.add, 2, rd: rd, rs2: rs2);
        }
        if (rs2 == 0) {
          if (rd == 0) return _fallback(page, slot, 2);
          return _store(page, slot, PredecodeOp.jalr, 2, rd: 1, rs1: rd);
        }
        if (rd == 0) return _nop(page, slot, 2);
        return _store(
          page,
          slot,
          PredecodeOp.add,
          2,
          rd: rd,
          rs1: rd,
          rs2: rs2,
        );
      case 6:
        final imm = _cdField(insn, 9, 2, 5) | _cdField(insn, 7, 6, 7);
        return _store(
          page,
          slot,
          PredecodeOp.sw,
          2,
          rs1: 2,
          rs2: rs2,
          imm: imm,
        );
      case 7:
        final imm = _cdField(insn, 10, 3, 5) | _cdField(insn, 7, 6, 8);
        return _store(
          page,
          slot,
          PredecodeOp.sd,
          2,
          rs1: 2,
          rs2: rs2,
          imm: imm,
        );
    }
    return _fallback(page, slot, 2);
  }

  static const _compressedMask = 0x03;
}

int _cdField(int insn, int srcPos, int dstPos, int dstPosMax) {
  final width = dstPosMax - dstPos + 1;
  final mask = ((1 << width) - 1) << dstPos;
  if (dstPos >= srcPos) {
    return (insn << (dstPos - srcPos)) & mask;
  }
  return (insn >>> (srcPos - dstPos)) & mask;
}

int _cdSignExtend(int value, int bits) {
  final signBit = 1 << (bits - 1);
  return (value ^ signBit) - signBit;
}

int _cdJImm(int insn) => _cdSignExtend(
  _cdField(insn, 12, 11, 11) |
      _cdField(insn, 11, 4, 4) |
      _cdField(insn, 9, 8, 9) |
      _cdField(insn, 8, 10, 10) |
      _cdField(insn, 7, 6, 6) |
      _cdField(insn, 6, 7, 7) |
      _cdField(insn, 3, 1, 3) |
      _cdField(insn, 2, 5, 5),
  12,
);

int _cdBranchImm(int insn) => _cdSignExtend(
  _cdField(insn, 12, 8, 8) |
      _cdField(insn, 10, 3, 4) |
      _cdField(insn, 5, 6, 7) |
      _cdField(insn, 3, 1, 2) |
      _cdField(insn, 2, 5, 5),
  9,
);

class _Opcode {
  static const lui = 0x37;
  static const auipc = 0x17;
  static const jal = 0x6F;
  static const jalr = 0x67;
  static const branch = 0x63;
  static const load = 0x03;
  static const store = 0x23;
  static const opImm = 0x13;
  static const opImm32 = 0x1B;
  static const op = 0x33;
  static const op32 = 0x3B;
}

/// Decodes RV32 instructions (including compressed) into micro-ops.
///
/// Emits the same op set as [Rv64Predecoder] minus 64-bit-only ops;
/// anything RV32-invalid or uncovered decodes to [PredecodeOp.fallback]
/// so the classic interpreter provides exact trap semantics.
class Rv32Predecoder {
  /// Decodes the instruction at [slot] of [page] and stores the result.
  static int decodeSlot(DecodedPage page, int slot) {
    final byteOffset = page.sourceOffset + slot * 2;
    final low = page.source.getUint16(byteOffset, Endian.little);

    if ((low & _compressedMask) != _compressedMask) {
      _decodeCompressed(page, slot, low);
      return page.meta[slot];
    }

    if (slot == DecodedPage.slotCount - 1) {
      _fallback(page, slot, 4);
      return page.meta[slot];
    }

    final insn =
        low | (page.source.getUint16(byteOffset + 2, Endian.little) << 16);
    _decodeFull(page, slot, insn);
    return page.meta[slot];
  }

  static void _store(
    DecodedPage page,
    int slot,
    int op,
    int size, {
    int rd = 0,
    int rs1 = 0,
    int rs2 = 0,
    int imm = 0,
  }) {
    page.imm[slot] = imm;
    page.meta[slot] =
        op |
        (rd << PredecodeMeta.rdShift) |
        (rs1 << PredecodeMeta.rs1Shift) |
        (rs2 << PredecodeMeta.rs2Shift) |
        ((size == 4 ? 1 : 0) << PredecodeMeta.sizeShift);
  }

  static void _fallback(DecodedPage page, int slot, int size) {
    _store(page, slot, PredecodeOp.fallback, size);
  }

  static void _nop(DecodedPage page, int slot, int size) {
    _store(page, slot, PredecodeOp.nop, size);
  }

  static void _decodeFull(DecodedPage page, int slot, int insn) {
    final opcode = insn & 0x7F;
    final rd = (insn >> 7) & 0x1F;
    final rs1 = (insn >> 15) & 0x1F;
    final rs2 = (insn >> 20) & 0x1F;
    final funct3 = (insn >> 12) & 0x7;
    final funct7 = insn >>> 25;

    switch (opcode) {
      case _Opcode.lui:
        if (rd == 0) return _nop(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.lui,
          4,
          rd: rd,
          imm: (insn & 0xFFFFF000).toSigned(32),
        );

      case _Opcode.auipc:
        if (rd == 0) return _nop(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.auipc,
          4,
          rd: rd,
          imm: (insn & 0xFFFFF000).toSigned(32),
        );

      case _Opcode.jal:
        final imm = InstructionDecoder.extractImmJ(insn);
        if (rd == 0) {
          return _store(page, slot, PredecodeOp.j, 4, imm: imm);
        }
        return _store(page, slot, PredecodeOp.jal, 4, rd: rd, imm: imm);

      case _Opcode.jalr:
        if (funct3 != 0) return _fallback(page, slot, 4);
        final imm = InstructionDecoder.extractImmI(insn);
        if (rd == 0) {
          return _store(page, slot, PredecodeOp.jr, 4, rs1: rs1, imm: imm);
        }
        return _store(
          page,
          slot,
          PredecodeOp.jalr,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );

      case _Opcode.branch:
        const branchOps = [
          PredecodeOp.beq,
          PredecodeOp.bne,
          -1,
          -1,
          PredecodeOp.blt,
          PredecodeOp.bge,
          PredecodeOp.bltu,
          PredecodeOp.bgeu,
        ];
        final branchOp = branchOps[funct3];
        if (branchOp < 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          branchOp,
          4,
          rs1: rs1,
          rs2: rs2,
          imm: InstructionDecoder.extractImmB(insn),
        );

      case _Opcode.load:
        if (rd == 0 || funct3 == 3 || funct3 > 5) {
          return _fallback(page, slot, 4);
        }
        const loadOps = [
          PredecodeOp.lb,
          PredecodeOp.lh,
          PredecodeOp.lw,
          -1,
          PredecodeOp.lbu,
          PredecodeOp.lhu,
        ];
        return _store(
          page,
          slot,
          loadOps[funct3],
          4,
          rd: rd,
          rs1: rs1,
          imm: InstructionDecoder.extractImmI(insn),
        );

      case _Opcode.store:
        if (funct3 > 2) return _fallback(page, slot, 4);
        const storeOps = [PredecodeOp.sb, PredecodeOp.sh, PredecodeOp.sw];
        return _store(
          page,
          slot,
          storeOps[funct3],
          4,
          rs1: rs1,
          rs2: rs2,
          imm: InstructionDecoder.extractImmS(insn),
        );

      case _Opcode.opImm:
        return _decodeOpImm(page, slot, insn, rd, rs1, funct3);

      case _Opcode.op:
        if (funct7 == 1) {
          if (rd == 0) return _fallback(page, slot, 4);
          return _store(
            page,
            slot,
            PredecodeOp.mulDiv,
            4,
            rd: rd,
            rs1: rs1,
            rs2: rs2,
            imm: funct3,
          );
        }
        return _decodeOpReg(page, slot, insn, rd, rs1, rs2, funct3, funct7);

      default:
        return _fallback(page, slot, 4);
    }
  }

  static void _decodeOpImm(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int funct3,
  ) {
    if (rd == 0) return _nop(page, slot, 4);
    final imm = InstructionDecoder.extractImmI(insn);
    switch (funct3) {
      case 0:
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 1:
        if ((imm & ~31) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          PredecodeOp.slli,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 31,
        );
      case 2:
        return _store(
          page,
          slot,
          PredecodeOp.slti,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 3:
        return _store(
          page,
          slot,
          PredecodeOp.sltiu,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 4:
        return _store(
          page,
          slot,
          PredecodeOp.xori,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 5:
        final isArith = (imm & 0x400) != 0;
        if ((imm & ~(31 | 0x400)) != 0) return _fallback(page, slot, 4);
        return _store(
          page,
          slot,
          isArith ? PredecodeOp.srai : PredecodeOp.srli,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm & 31,
        );
      case 6:
        return _store(
          page,
          slot,
          PredecodeOp.ori,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
      case 7:
        return _store(
          page,
          slot,
          PredecodeOp.andi,
          4,
          rd: rd,
          rs1: rs1,
          imm: imm,
        );
    }
    return _fallback(page, slot, 4);
  }

  static void _decodeOpReg(
    DecodedPage page,
    int slot,
    int insn,
    int rd,
    int rs1,
    int rs2,
    int funct3,
    int funct7,
  ) {
    if ((funct7 & ~0x20) != 0) return _fallback(page, slot, 4);
    if (rd == 0) return _nop(page, slot, 4);
    final alt = funct7 == 0x20;
    final regOp = switch ((funct3, alt)) {
      (0, false) => PredecodeOp.add,
      (0, true) => PredecodeOp.sub,
      (1, false) => PredecodeOp.sll,
      (2, false) => PredecodeOp.slt,
      (3, false) => PredecodeOp.sltu,
      (4, false) => PredecodeOp.xor,
      (5, false) => PredecodeOp.srl,
      (5, true) => PredecodeOp.sra,
      (6, false) => PredecodeOp.or,
      (7, false) => PredecodeOp.and,
      _ => -1,
    };
    if (regOp < 0) return _fallback(page, slot, 4);
    _store(page, slot, regOp, 4, rd: rd, rs1: rs1, rs2: rs2);
  }

  static void _decodeCompressed(DecodedPage page, int slot, int insn) {
    final quadrant = insn & _compressedMask;
    final funct3 = (insn >> 13) & 0x7;

    switch (quadrant) {
      case 0:
        return _decodeCompressedQ0(page, slot, insn, funct3);
      case 1:
        return _decodeCompressedQ1(page, slot, insn, funct3);
      case 2:
        return _decodeCompressedQ2(page, slot, insn, funct3);
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ0(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rdPrime = ((insn >> 2) & 7) | 8;
    final rs1Prime = ((insn >> 7) & 7) | 8;

    switch (funct3) {
      case 0:
        final imm =
            _cdField(insn, 11, 4, 5) |
            _cdField(insn, 7, 6, 9) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 3, 3);
        if (imm == 0) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          2,
          rd: rdPrime,
          rs1: 2,
          imm: imm,
        );
      case 2:
        final imm =
            _cdField(insn, 10, 3, 5) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 6, 6);
        return _store(
          page,
          slot,
          PredecodeOp.lw,
          2,
          rd: rdPrime,
          rs1: rs1Prime,
          imm: imm,
        );
      case 6:
        final imm =
            _cdField(insn, 10, 3, 5) |
            _cdField(insn, 6, 2, 2) |
            _cdField(insn, 5, 6, 6);
        return _store(
          page,
          slot,
          PredecodeOp.sw,
          2,
          rs1: rs1Prime,
          rs2: rdPrime,
          imm: imm,
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ1(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rd = (insn >> 7) & 0x1F;

    switch (funct3) {
      case 0:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(
          page,
          slot,
          PredecodeOp.addi,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 1:
        return _store(
          page,
          slot,
          PredecodeOp.jal,
          2,
          rd: 1,
          imm: _cdJImm(insn),
        );
      case 2:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(page, slot, PredecodeOp.addi, 2, rd: rd, imm: imm);
      case 3:
        if (rd == 2) {
          final imm = _cdSignExtend(
            _cdField(insn, 12, 9, 9) |
                _cdField(insn, 6, 4, 4) |
                _cdField(insn, 5, 6, 6) |
                _cdField(insn, 3, 7, 8) |
                _cdField(insn, 2, 5, 5),
            10,
          );
          if (imm == 0) return _fallback(page, slot, 2);
          return _store(
            page,
            slot,
            PredecodeOp.addi,
            2,
            rd: 2,
            rs1: 2,
            imm: imm,
          );
        }
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdSignExtend(
          _cdField(insn, 12, 17, 17) | _cdField(insn, 2, 12, 16),
          18,
        );
        return _store(page, slot, PredecodeOp.lui, 2, rd: rd, imm: imm);
      case 4:
        return _decodeCompressedArith(page, slot, insn);
      case 5:
        return _store(page, slot, PredecodeOp.j, 2, imm: _cdJImm(insn));
      case 6:
        final rs1Prime = ((insn >> 7) & 7) | 8;
        return _store(
          page,
          slot,
          PredecodeOp.beq,
          2,
          rs1: rs1Prime,
          imm: _cdBranchImm(insn),
        );
      case 7:
        final rs1Prime = ((insn >> 7) & 7) | 8;
        return _store(
          page,
          slot,
          PredecodeOp.bne,
          2,
          rs1: rs1Prime,
          imm: _cdBranchImm(insn),
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedArith(DecodedPage page, int slot, int insn) {
    final subFunct = (insn >> 10) & 3;
    final rd = ((insn >> 7) & 7) | 8;

    switch (subFunct) {
      case 0:
      case 1:
        final imm = _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4);
        if ((imm & 0x20) != 0) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          subFunct == 0 ? PredecodeOp.srli : PredecodeOp.srai,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 2:
        final imm = _cdSignExtend(
          _cdField(insn, 12, 5, 5) | _cdField(insn, 2, 0, 4),
          6,
        );
        return _store(
          page,
          slot,
          PredecodeOp.andi,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 3:
        final rs2 = ((insn >> 2) & 7) | 8;
        final subOp = ((insn >> 5) & 3) | ((insn >> 10) & 4);
        const arithOps = [
          PredecodeOp.sub,
          PredecodeOp.xor,
          PredecodeOp.or,
          PredecodeOp.and,
        ];
        if (subOp >= arithOps.length) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          arithOps[subOp],
          2,
          rd: rd,
          rs1: rd,
          rs2: rs2,
        );
    }
    return _fallback(page, slot, 2);
  }

  static void _decodeCompressedQ2(
    DecodedPage page,
    int slot,
    int insn,
    int funct3,
  ) {
    final rd = (insn >> 7) & 0x1F;
    final rs2 = (insn >> 2) & 0x1F;

    switch (funct3) {
      case 0:
        if (rd == 0) return _nop(page, slot, 2);
        final imm = _cdField(insn, 12, 5, 5) | rs2;
        if ((imm & 0x20) != 0) return _fallback(page, slot, 2);
        return _store(
          page,
          slot,
          PredecodeOp.slli,
          2,
          rd: rd,
          rs1: rd,
          imm: imm,
        );
      case 2:
        if (rd == 0) return _fallback(page, slot, 2);
        final imm =
            _cdField(insn, 12, 5, 5) |
            (rs2 & (7 << 2)) |
            _cdField(insn, 2, 6, 7);
        return _store(page, slot, PredecodeOp.lw, 2, rd: rd, rs1: 2, imm: imm);
      case 4:
        final bit12 = (insn >> 12) & 1;
        if (bit12 == 0) {
          if (rs2 == 0) {
            if (rd == 0) return _fallback(page, slot, 2);
            return _store(page, slot, PredecodeOp.jr, 2, rs1: rd);
          }
          if (rd == 0) return _nop(page, slot, 2);
          return _store(page, slot, PredecodeOp.add, 2, rd: rd, rs2: rs2);
        }
        if (rs2 == 0) {
          if (rd == 0) return _fallback(page, slot, 2);
          return _store(page, slot, PredecodeOp.jalr, 2, rd: 1, rs1: rd);
        }
        if (rd == 0) return _nop(page, slot, 2);
        return _store(
          page,
          slot,
          PredecodeOp.add,
          2,
          rd: rd,
          rs1: rd,
          rs2: rs2,
        );
      case 6:
        final imm = _cdField(insn, 9, 2, 5) | _cdField(insn, 7, 6, 7);
        return _store(
          page,
          slot,
          PredecodeOp.sw,
          2,
          rs1: 2,
          rs2: rs2,
          imm: imm,
        );
    }
    return _fallback(page, slot, 2);
  }

  static const _compressedMask = 0x03;
}
