import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/csr.dart';
import 'package:dart_emu/src/cpu/decoder.dart';
import 'package:dart_emu/src/cpu/exception.dart';
import 'package:dart_emu/src/cpu/extensions/a_extension.dart';
import 'package:dart_emu/src/cpu/extensions/d_extension.dart';
import 'package:dart_emu/src/cpu/extensions/f_extension.dart';
import 'package:dart_emu/src/cpu/extensions/m_extension.dart';
import 'package:dart_emu/src/cpu/mmu.dart';
import 'package:dart_emu/src/cpu/predecode.dart';
import 'package:dart_emu/src/cpu/tlb.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:dart_emu/src/machine/phys_memory_range.dart';
import 'package:dart_emu/src/util/bit_utils.dart';

/// Pair-frequency data recorded when compiled with
/// -DDARTEMU_COUNT_PAIRS=true; indexed by (prevOp << 8) | op.
Int64List debugPredecodePairCounts() => _CpuExecutor64.pairCounts;

class CpuExecutor {
  factory CpuExecutor({required PhysMemoryMap memMap, Xlen xlen = Xlen.rv64}) =>
      switch (xlen) {
        Xlen.rv32 => _CpuExecutor32(memMap: memMap),
        Xlen.rv64 => _CpuExecutor64(memMap: memMap),
      };

  CpuExecutor._({required PhysMemoryMap memMap, required Xlen xlen})
    : state = RiscVCpuState(memMap: memMap, xlen: xlen) {
    memMap.onRamWritten = _onRamWritten;
    csrHandler = CsrHandler(state: state);
    exceptionHandler = ExceptionHandler(state: state);
    mmu = Mmu(state: state);
    _mExt = MExtension(xlen: xlen);
    _aExt = AExtension(state: state);
    _fExt = FExtension(state: state);
    _dExt = DExtension(state: state);
    _initMisa();
    state.onTlbFlush = _invalidateCodeCache;
  }

  final RiscVCpuState state;
  late CsrHandler csrHandler;
  late ExceptionHandler exceptionHandler;
  late Mmu mmu;
  late MExtension _mExt;
  late AExtension _aExt;
  late FExtension _fExt;
  late DExtension _dExt;

  ByteData _codeData = _emptyByteData;
  int _codeBase = 0;
  int _codeEnd = 0;
  int _codePageTag = _invalidCodeTag;

  static final ByteData _emptyByteData = ByteData(0);
  static const _invalidCodeTag = -1;

  int get cycles => state.instructionCounter;

  bool get powerDown => state.powerDown;

  void _invalidateCodeCache() {
    _codePageTag = _invalidCodeTag;
  }

  /// Invalidates caches derived from instruction bytes (`fence.i`).
  void _invalidateInstructionCaches() {
    _invalidateCodeCache();
    _predecodeCache.invalidateAll();
  }

  final PredecodeCache _predecodeCache = PredecodeCache();
  DecodedPage? _decodedPage;

  static final DecodedPage _sentinelPage = DecodedPage(ByteData(0), -1);

  /// Removes write-TLB entries covering a freshly decoded page, so the
  /// next guest store to it takes the slow path and reaches
  /// [_onGuestStorePage].
  void _purgeWriteTlbForPage(ByteData data, int pageBase) {
    final tlbWrite = state.tlbWrite;
    for (var i = 0; i < tlbWrite.length; i++) {
      final entry = tlbWrite[i];
      if (entry.hostOffset == pageBase && identical(entry.hostData, data)) {
        entry.invalidate();
      }
    }
  }

  void _onRamWritten(int physAddr, int length) {
    final range = state.memMap.findRange(physAddr);
    if (range is! RamRange) return;
    final first = (physAddr - range.addr) & ~TlbConstants.pageMask;
    final last = (physAddr - range.addr + length - 1) & ~TlbConstants.pageMask;
    for (var page = first; page <= last; page += TlbConstants.pageSize) {
      _dropDecodedPage(range.byteData, page);
    }
  }

  void _dropDecodedPage(ByteData data, int pageBase) {
    if (_predecodeCache.invalidatePage(data, pageBase) &&
        pageBase == _codeBase &&
        identical(data, _codeData)) {
      _invalidateCodeCache();
    }
  }

  /// Executes up to [maxCycles] instructions.
  void execute(int maxCycles) {
    if (maxCycles <= 0) return;

    final counterTarget = state.instructionCounter + maxCycles;
    state.nCycles = maxCycles;

    if (_hasPendingInterrupt()) {
      _handleInterrupt();
      state.nCycles--;
      _syncCounter(counterTarget);
      return;
    }

    state.pendingException = _noPendingException;

    while (state.nCycles > 0) {
      if (_hasPendingInterrupt()) {
        _handleInterrupt();
        state.nCycles--;
        break;
      }

      final insn = _fetchInstruction();
      if (state.pendingException >= 0) {
        _handlePendingException(counterTarget);
        return;
      }

      state.nCycles--;

      final compressed = InstructionDecoder.isCompressed(insn);
      final instrSize = compressed ? _compressedInsnSize : _fullInsnSize;

      if (!_executeInstruction(insn, instrSize)) {
        _handlePendingException(counterTarget);
        return;
      }

      if (state.powerDown) break;
    }

    _syncCounter(counterTarget);
  }

  void setMip(int mask) => state.setMip(mask);

  void resetMip(int mask) => state.resetMip(mask);

  int get mip => state.mip;

  bool _hasPendingInterrupt() =>
      (state.mip & state.mie) != 0 && exceptionHandler.hasPendingInterrupt();

  void _handleInterrupt() => exceptionHandler.handlePendingInterrupt();

  void _syncCounter(int counterTarget) {
    state.instructionCounter = counterTarget - state.nCycles;
  }

  int _fetchInstruction() {
    final addr = state.pc;
    final pageTag = addr & ~TlbConstants.pageMask;

    if (pageTag == _codePageTag) {
      final offset = _codeBase + (addr & TlbConstants.pageMask);
      final remaining = _codeEnd - offset;
      if (remaining >= _fullInsnSize) {
        return _readInsn32(_codeData, offset);
      }
      if (remaining >= _compressedInsnSize) {
        final low = _codeData.getUint16(offset, Endian.little);
        if ((low & _compressedMask) != _compressedMask) {
          return low;
        }
        return _fetchCrossPage(addr, low);
      }
    }

    return _fetchSlowAndCache(addr);
  }

  int _readFromCodePage(int addr) {
    final offset = _codeBase + (addr & TlbConstants.pageMask);
    final remaining = _codeEnd - offset;
    if (remaining >= _fullInsnSize) {
      return _readInsn32(_codeData, offset);
    }
    if (remaining >= _compressedInsnSize) {
      final low = _codeData.getUint16(offset, Endian.little);
      if ((low & _compressedMask) != _compressedMask) {
        return low;
      }
      return _fetchCrossPage(addr, low);
    }
    return _fetchSlow(addr);
  }

  int _fetchSlowAndCache(int addr) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final entry = state.tlbCode[tlbIdx];

    if (entry.virtualTag == (addr & ~TlbConstants.pageMask)) {
      _installCodePage(entry);
      return _readFromCodePage(addr);
    }

    final result = _fetchSlow(addr);
    if (state.pendingException >= 0) return 0;

    _installCodePage(state.tlbCode[tlbIdx]);
    return result;
  }

  void _installCodePage(TlbEntry entry) {
    _codeData = entry.hostData;
    _codeBase = entry.hostOffset;
    _codeEnd = entry.hostOffset + TlbConstants.pageSize;
    _codePageTag = entry.virtualTag;

    var page = _predecodeCache.lookup(entry.hostData, entry.hostOffset);
    if (page == null) {
      page = _predecodeCache.insert(entry.hostData, entry.hostOffset);
      _purgeWriteTlbForPage(entry.hostData, entry.hostOffset);
    }
    _decodedPage = page;
  }

  int _readInsn32(ByteData data, int offset) {
    final word = data.getUint32(offset, Endian.little);
    if ((word & _compressedMask) != _compressedMask) {
      return word & _halfWordMask;
    }
    return word;
  }

  int _fetchSlow(int addr) {
    try {
      final physAddr = mmu.translate(addr, MemoryAccessType.fetch);
      final range = state.memMap.findRange(physAddr);
      if (range == null || range is! RamRange) {
        state
          ..pendingException = _Exception.faultFetch
          ..pendingTval = addr;
        return 0;
      }

      final pageOffset = addr & TlbConstants.pageMask;
      final rangeOffset = physAddr - range.addr;
      final pageBase = rangeOffset - pageOffset;

      final tlbIdx =
          (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
      state.tlbCode[tlbIdx]
        ..virtualTag = addr & ~TlbConstants.pageMask
        ..hostData = range.byteData
        ..hostOffset = pageBase;

      final offset = pageBase + pageOffset;
      final remaining = TlbConstants.pageSize - pageOffset;

      if (remaining >= _fullInsnSize) {
        return _readInsn32(range.byteData, offset);
      }

      if (remaining >= _compressedInsnSize) {
        final low = range.byteData.getUint16(offset, Endian.little);
        if ((low & _compressedMask) != _compressedMask) {
          return low;
        }
        return _fetchCrossPage(addr, low);
      }

      state
        ..pendingException = _Exception.faultFetch
        ..pendingTval = addr;
      return 0;
    } on MmuException catch (e) {
      state
        ..pendingException = e.causeCode
        ..pendingTval = e.virtualAddr;
      return 0;
    }
  }

  int _fetchCrossPage(int addr, int lowHalf) {
    try {
      final nextAddr = addr + _compressedInsnSize;
      final physAddr = mmu.translate(nextAddr, MemoryAccessType.fetch);
      final range = state.memMap.findRange(physAddr);
      if (range == null || range is! RamRange) {
        state
          ..pendingException = _Exception.faultFetch
          ..pendingTval = nextAddr;
        return 0;
      }
      final offset = physAddr - range.addr;
      final high = range.byteData.getUint16(offset, Endian.little);
      return lowHalf | (high << _halfWordBits);
    } on MmuException catch (e) {
      state
        ..pendingException = e.causeCode
        ..pendingTval = e.virtualAddr;
      return 0;
    }
  }

  void _handlePendingException(int counterTarget) {
    if (state.pendingException >= 0) {
      state.nCycles--;
      exceptionHandler.raiseException(
        state.pendingException,
        state.pendingTval,
      );
    }
    _syncCounter(counterTarget);
  }

  bool _executeInstruction(int insn, int instrSize) {
    final opcode = insn & _opcodeMask;

    switch (opcode) {
      case _Opcode.lui:
        final rd = (insn >> 7) & _regMask;
        if (rd != 0) {
          state.regs[rd] = BitUtils.signExtend32(insn & _immUMask);
        }
        state.pc += instrSize;
        return true;
      case _Opcode.auipc:
        final rd = (insn >> 7) & _regMask;
        if (rd != 0) {
          state.regs[rd] = state.pc + BitUtils.signExtend32(insn & _immUMask);
        }
        state.pc += instrSize;
        return true;
      case _Opcode.jal:
        final rd = (insn >> 7) & _regMask;
        if (rd != 0) {
          state.regs[rd] = state.pc + _fullInsnSize;
        }
        state.pc += InstructionDecoder.extractImmJ(insn);
        return true;
      case _Opcode.jalr:
        final rd = (insn >> 7) & _regMask;
        final rs1 = (insn >> 15) & _regMask;
        final imm = InstructionDecoder.extractImmI(insn);
        final returnAddr = state.pc + _fullInsnSize;
        state.pc = (state.regs[rs1] + imm) & ~1;
        if (rd != 0) state.regs[rd] = returnAddr;
        return true;
      case _Opcode.branch:
        final funct3 = (insn >> 12) & 7;
        if (funct3 <= 1) {
          final rs1 = (insn >> 15) & _regMask;
          final rs2 = (insn >> 20) & _regMask;
          final eq = state.regs[rs1] == state.regs[rs2];
          final taken = funct3 == 0 ? eq : !eq;
          if (taken) {
            state.pc += InstructionDecoder.extractImmB(insn);
          } else {
            state.pc += instrSize;
          }
          return true;
        }
        return _executeBranch(insn, instrSize);
      case _Opcode.load:
        return _executeLoad(insn, instrSize);
      case _Opcode.loadFp:
        return _executeLoadFp(insn, instrSize);
      case _Opcode.store:
        return _executeStore(insn, instrSize);
      case _Opcode.storeFp:
        return _executeStoreFp(insn, instrSize);
      case _Opcode.opImm:
        return _executeOpImm(insn, instrSize);
      case _Opcode.opImm32:
        return _executeOpImm32(insn, instrSize);
      case _Opcode.op:
        return _executeOp(insn, instrSize);
      case _Opcode.op32:
        return _executeOp32(insn, instrSize);
      case _Opcode.system:
        return _executeSystem(insn, instrSize);
      case _Opcode.miscMem:
        return _executeMiscMem(insn, instrSize);
      case _Opcode.amo:
        return _executeAmo(insn, instrSize);
      case _Opcode.fmadd:
      case _Opcode.fmsub:
      case _Opcode.fnmsub:
      case _Opcode.fnmadd:
        return _executeFusedMulAdd(insn, instrSize, opcode);
      case _Opcode.opFp:
        return _executeOpFp(insn, instrSize);
      default:
        if (instrSize == _compressedInsnSize) {
          return _executeCompressed(insn);
        }
        _raiseIllegalInsn(insn);
        return false;
    }
  }

  bool _executeCompressed(int insn) {
    final quadrant = insn & _compressedMask;
    final funct3 = (insn >> _cFunct3Shift) & _cFunct3Mask;

    return switch (quadrant) {
      0 => _executeCompressedQ0(insn, funct3),
      1 => _executeCompressedQ1(insn, funct3),
      2 => _executeCompressedQ2(insn, funct3),
      _ => _illegalCompressed(insn),
    };
  }

  bool _illegalCompressed(int insn) {
    _raiseIllegalInsn(insn);
    return false;
  }

  bool _executeCompressedQ0(int insn, int funct3) {
    final rdPrime = ((insn >> 2) & 7) | 8;

    return switch (funct3) {
      0 => _cAddi4spn(insn, rdPrime),
      1 => _cFld(insn, rdPrime),
      2 => _cLw(insn, rdPrime),
      3 => _cLd(insn, rdPrime),
      5 => _cFsd(insn, rdPrime),
      6 => _cSw(insn, rdPrime),
      7 => _cSd(insn, rdPrime),
      _ => _illegalCompressed(insn),
    };
  }

  bool _cAddi4spn(int insn, int rd) {
    final imm =
        _cField(insn, 11, 4, 5) |
        _cField(insn, 7, 6, 9) |
        _cField(insn, 6, 2, 2) |
        _cField(insn, 5, 3, 3);
    if (imm == 0) {
      _raiseIllegalInsn(insn);
      return false;
    }
    _writeReg(rd, state.regs[2] + imm);
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLw(int insn, int rd) {
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm =
        _cField(insn, 10, 3, 5) |
        _cField(insn, 6, 2, 2) |
        _cField(insn, 5, 6, 6);
    final addr = state.regs[rs1] + imm;
    final val = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    _writeReg(rd, BitUtils.signExtend32(val));
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLd(int insn, int rd) {
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 5, 6, 7);
    final addr = state.regs[rs1] + imm;
    final val = _memReadU64(addr);
    if (state.pendingException >= 0) return false;
    _writeReg(rd, val);
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cSw(int insn, int rdPrime) {
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm =
        _cField(insn, 10, 3, 5) |
        _cField(insn, 6, 2, 2) |
        _cField(insn, 5, 6, 6);
    final addr = state.regs[rs1] + imm;
    if (!_memWriteU32(addr, state.regs[rdPrime])) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cSd(int insn, int rdPrime) {
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 5, 6, 7);
    final addr = state.regs[rs1] + imm;
    if (!_memWriteU64(addr, state.regs[rdPrime])) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFld(int insn, int rd) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 5, 6, 7);
    final addr = state.regs[rs1] + imm;
    final lo = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    final hi = _memReadU32(addr + _wordSize);
    if (state.pendingException >= 0) return false;
    state.fpRegs.writePair(rd, lo, hi);
    _markFsDirty();
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFsd(int insn, int rs2Prime) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 5, 6, 7);
    final addr = state.regs[rs1] + imm;
    if (!_memWriteU32(addr, state.fpRegs.readLo(rs2Prime))) {
      return false;
    }
    if (!_memWriteU32(addr + _wordSize, state.fpRegs.readHi(rs2Prime))) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFlw(int insn, int rd) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm =
        _cField(insn, 10, 3, 5) |
        _cField(insn, 6, 2, 2) |
        _cField(insn, 5, 6, 6);
    final addr = state.regs[rs1] + imm;
    final val = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    state.fpRegs.writeWithNanBox(rd, val & _mask32);
    _markFsDirty();
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFsw(int insn, int rs2Prime) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rs1 = ((insn >> 7) & 7) | 8;
    final imm =
        _cField(insn, 10, 3, 5) |
        _cField(insn, 6, 2, 2) |
        _cField(insn, 5, 6, 6);
    final addr = state.regs[rs1] + imm;
    if (!_memWriteU32(addr, state.fpRegs.readLo(rs2Prime))) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _executeCompressedQ1(int insn, int funct3) => switch (funct3) {
    0 => _cAddiNop(insn),
    1 => _cAddiw(insn),
    2 => _cLi(insn),
    3 => _cLuiAddi16sp(insn),
    4 => _cArith(insn),
    5 => _cJ(insn),
    6 => _cBeqz(insn),
    7 => _cBnez(insn),
    _ => _illegalCompressed(insn),
  };

  bool _cAddiNop(int insn) {
    final rd = InstructionDecoder.extractRd(insn);
    if (rd != 0) {
      final imm = _cSignExtend(
        _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4),
        6,
      );
      _writeReg(rd, state.regs[rd] + imm);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cAddiw(int insn) {
    final rd = InstructionDecoder.extractRd(insn);
    if (rd != 0) {
      final imm = _cSignExtend(
        _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4),
        6,
      );
      _writeReg(rd, BitUtils.signExtend32(state.regs[rd] + imm));
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLi(int insn) {
    final rd = InstructionDecoder.extractRd(insn);
    if (rd != 0) {
      final imm = _cSignExtend(
        _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4),
        6,
      );
      _writeReg(rd, imm);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLuiAddi16sp(int insn) {
    final rd = InstructionDecoder.extractRd(insn);
    if (rd == 2) {
      final imm = _cSignExtend(
        _cField(insn, 12, 9, 9) |
            _cField(insn, 6, 4, 4) |
            _cField(insn, 5, 6, 6) |
            _cField(insn, 3, 7, 8) |
            _cField(insn, 2, 5, 5),
        10,
      );
      if (imm == 0) {
        _raiseIllegalInsn(insn);
        return false;
      }
      _writeReg(2, state.regs[2] + imm);
    } else if (rd != 0) {
      final imm = _cSignExtend(
        _cField(insn, 12, 17, 17) | _cField(insn, 2, 12, 16),
        18,
      );
      _writeReg(rd, imm);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cArith(int insn) {
    final subFunct = (insn >> 10) & 3;
    final rd = ((insn >> 7) & 7) | 8;

    return switch (subFunct) {
      0 || 1 => _cShift(insn, rd, subFunct),
      2 => _cAndi(insn, rd),
      3 => _cRegArith(insn, rd),
      _ => _illegalCompressed(insn),
    };
  }

  bool _cShift(int insn, int rd, int isArith) {
    final imm = _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4);
    if (isArith == 0) {
      _writeReg(rd, state.regs[rd] >>> imm);
    } else {
      _writeReg(rd, state.regs[rd] >> imm);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cAndi(int insn, int rd) {
    final imm = _cSignExtend(
      _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4),
      6,
    );
    _writeReg(rd, state.regs[rd] & imm);
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cRegArith(int insn, int rd) {
    final rs2 = ((insn >> 2) & 7) | 8;
    final subOp = ((insn >> 5) & 3) | ((insn >> (12 - 2)) & 4);

    switch (subOp) {
      case 0:
        _writeReg(rd, state.regs[rd] - state.regs[rs2]);
      case 1:
        _writeReg(rd, state.regs[rd] ^ state.regs[rs2]);
      case 2:
        _writeReg(rd, state.regs[rd] | state.regs[rs2]);
      case 3:
        _writeReg(rd, state.regs[rd] & state.regs[rs2]);
      case 4:
        _writeReg(rd, BitUtils.signExtend32(state.regs[rd] - state.regs[rs2]));
      case 5:
        _writeReg(rd, BitUtils.signExtend32(state.regs[rd] + state.regs[rs2]));
      default:
        _raiseIllegalInsn(insn);
        return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cJal(int insn) {
    _writeReg(_raReg, state.pc + _compressedInsnSize);
    state.pc += _cJImm(insn);
    return true;
  }

  bool _cJ(int insn) {
    state.pc += _cJImm(insn);
    return true;
  }

  bool _cBeqz(int insn) {
    final rs1 = ((insn >> 7) & 7) | 8;
    if (state.regs[rs1] == 0) {
      state.pc += _cBranchImm(insn);
    } else {
      state.pc += _compressedInsnSize;
    }
    return true;
  }

  bool _cBnez(int insn) {
    final rs1 = ((insn >> 7) & 7) | 8;
    if (state.regs[rs1] != 0) {
      state.pc += _cBranchImm(insn);
    } else {
      state.pc += _compressedInsnSize;
    }
    return true;
  }

  bool _executeCompressedQ2(int insn, int funct3) {
    final rs2 = (insn >> 2) & _regMask;

    return switch (funct3) {
      0 => _cSlli(insn, rs2),
      1 => _cFldsp(insn),
      2 => _cLwsp(insn, rs2),
      3 => _cLdsp(insn, rs2),
      4 => _cJrMvAddEbreak(insn, rs2),
      5 => _cFsdsp(insn, rs2),
      6 => _cSwsp(insn, rs2),
      7 => _cSdsp(insn, rs2),
      _ => _illegalCompressed(insn),
    };
  }

  bool _cSlli(int insn, int rs2) {
    final rd = InstructionDecoder.extractRd(insn);
    final imm = _cField(insn, 12, 5, 5) | rs2;
    if (rd != 0) {
      _writeReg(rd, state.regs[rd] << imm);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLwsp(int insn, int rs2) {
    final rd = InstructionDecoder.extractRd(insn);
    final imm =
        _cField(insn, 12, 5, 5) | (rs2 & (7 << 2)) | _cField(insn, 2, 6, 7);
    final addr = state.regs[2] + imm;
    final val = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    if (rd != 0) {
      _writeReg(rd, BitUtils.signExtend32(val));
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cLdsp(int insn, int rs2) {
    final rd = InstructionDecoder.extractRd(insn);
    final imm =
        _cField(insn, 12, 5, 5) | (rs2 & (3 << 3)) | _cField(insn, 2, 6, 8);
    final addr = state.regs[2] + imm;
    final val = _memReadU64(addr);
    if (state.pendingException >= 0) return false;
    if (rd != 0) {
      _writeReg(rd, val);
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cJrMvAddEbreak(int insn, int rs2) {
    final rd = InstructionDecoder.extractRd(insn);
    final bit12 = (insn >> 12) & 1;

    if (bit12 == 0) {
      if (rs2 == 0) {
        if (rd == 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        state.pc = state.regs[rd] & ~1;
        return true;
      } else {
        if (rd != 0) {
          _writeReg(rd, state.regs[rs2]);
        }
        state.pc += _compressedInsnSize;
        return true;
      }
    } else {
      if (rs2 == 0) {
        if (rd == 0) {
          state.pendingException = _Exception.breakpoint;
          return false;
        } else {
          final returnAddr = state.pc + _compressedInsnSize;
          state.pc = state.regs[rd] & ~1;
          _writeReg(1, returnAddr);
          return true;
        }
      } else {
        if (rd != 0) {
          _writeReg(rd, state.regs[rd] + state.regs[rs2]);
        }
        state.pc += _compressedInsnSize;
        return true;
      }
    }
  }

  bool _cSwsp(int insn, int rs2) {
    final imm = _cField(insn, 9, 2, 5) | _cField(insn, 7, 6, 7);
    final addr = state.regs[2] + imm;
    if (!_memWriteU32(addr, state.regs[rs2])) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cSdsp(int insn, int rs2) {
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 7, 6, 8);
    final addr = state.regs[2] + imm;
    if (!_memWriteU64(addr, state.regs[rs2])) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFldsp(int insn) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rd = InstructionDecoder.extractRd(insn);
    final rs2 = (insn >> 2) & _regMask;
    final imm =
        _cField(insn, 12, 5, 5) | (rs2 & (3 << 3)) | _cField(insn, 2, 6, 8);
    final addr = state.regs[2] + imm;
    final lo = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    final hi = _memReadU32(addr + _wordSize);
    if (state.pendingException >= 0) return false;
    state.fpRegs.writePair(rd, lo, hi);
    _markFsDirty();
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFsdsp(int insn, int rs2) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final imm = _cField(insn, 10, 3, 5) | _cField(insn, 7, 6, 8);
    final addr = state.regs[2] + imm;
    if (!_memWriteU32(addr, state.fpRegs.readLo(rs2))) {
      return false;
    }
    if (!_memWriteU32(addr + _wordSize, state.fpRegs.readHi(rs2))) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFlwsp(int insn, int rs2) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rd = InstructionDecoder.extractRd(insn);
    final imm =
        _cField(insn, 12, 5, 5) | (rs2 & (7 << 2)) | _cField(insn, 2, 6, 7);
    final addr = state.regs[2] + imm;
    final val = _memReadU32(addr);
    if (state.pendingException >= 0) return false;
    state.fpRegs.writeWithNanBox(rd, val & _mask32);
    _markFsDirty();
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _cFswsp(int insn, int rs2) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final imm = _cField(insn, 9, 2, 5) | _cField(insn, 7, 6, 7);
    final addr = state.regs[2] + imm;
    if (!_memWriteU32(addr, state.fpRegs.readLo(rs2))) {
      return false;
    }
    state.pc += _compressedInsnSize;
    return true;
  }

  bool _executeBranch(int insn, int instrSize) {
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final a = state.regs[rs1];
    final b = state.regs[rs2];

    bool condition;
    switch (funct3 >> 1) {
      case 0:
        condition = a == b;
      case 2:
        condition = a < b;
      case 3:
        condition = _unsignedLessThan(a, b);
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if ((funct3 & 1) != 0) condition = !condition;

    if (condition) {
      final imm = InstructionDecoder.extractImmB(insn);
      state.pc += imm;
    } else {
      state.pc += instrSize;
    }
    return true;
  }

  bool _executeLoad(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final addr = state.regs[rs1] + imm;

    int val;
    switch (funct3) {
      case _LoadFunct3.lb:
        val = _memReadU8(addr);
        if (state.pendingException >= 0) return false;
        val = _signExtend8(val);
      case _LoadFunct3.lh:
        val = _memReadU16(addr);
        if (state.pendingException >= 0) return false;
        val = _signExtend16(val);
      case _LoadFunct3.lw:
        val = _memReadU32(addr);
        if (state.pendingException >= 0) return false;
        val = BitUtils.signExtend32(val);
      case _LoadFunct3.ld:
        val = _memReadU64(addr);
        if (state.pendingException >= 0) return false;
      case _LoadFunct3.lbu:
        val = _memReadU8(addr);
        if (state.pendingException >= 0) return false;
      case _LoadFunct3.lhu:
        val = _memReadU16(addr);
        if (state.pendingException >= 0) return false;
      case _LoadFunct3.lwu:
        val = _memReadU32(addr);
        if (state.pendingException >= 0) return false;
        val = val & _mask32;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  bool _executeStore(int insn, int instrSize) {
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmS(insn);
    final addr = state.regs[rs1] + imm;
    final val = state.regs[rs2];

    switch (funct3) {
      case _StoreFunct3.sb:
        if (!_memWriteU8(addr, val)) return false;
      case _StoreFunct3.sh:
        if (!_memWriteU16(addr, val)) return false;
      case _StoreFunct3.sw:
        if (!_memWriteU32(addr, val)) return false;
      case _StoreFunct3.sd:
        if (!_memWriteU64(addr, val)) return false;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    state.pc += instrSize;
    return true;
  }

  bool _executeOpImm(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final src = state.regs[rs1];

    int val;
    switch (funct3) {
      case _AluFunct3.add:
        val = src + imm;
      case _AluFunct3.sll:
        if ((imm & ~_shamtMask64) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        val = src << (imm & _shamtMask64);
      case _AluFunct3.slt:
        val = (src < imm) ? 1 : 0;
      case _AluFunct3.sltu:
        val = _unsignedLessThan(src, imm) ? 1 : 0;
      case _AluFunct3.xor:
        val = src ^ imm;
      case _AluFunct3.srl:
        final shamtBits = imm & _shamtMask64;
        if ((imm & ~(_shamtMask64 | _sraBit)) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if ((imm & _sraBit) != 0) {
          val = src >> shamtBits;
        } else {
          val = src >>> shamtBits;
        }
      case _AluFunct3.or:
        val = src | imm;
      case _AluFunct3.and:
        val = src & imm;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  bool _executeOpImm32(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final src = state.regs[rs1];

    int val;
    switch (funct3) {
      case _AluFunct3.add:
        val = BitUtils.signExtend32(src + imm);
      case _AluFunct3.sll:
        if ((imm & ~_shamtMask32) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        val = BitUtils.signExtend32(src << (imm & _shamtMask32));
      case _AluFunct3.srl:
        final shamt = imm & _shamtMask32;
        if ((imm & ~(_shamtMask32 | _sraBit)) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if ((imm & _sraBit) != 0) {
          val = BitUtils.signExtend32(src) >> shamt;
        } else {
          val = BitUtils.signExtend32((src & _mask32) >>> shamt);
        }
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  bool _executeOp(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct7 = insn >>> _funct7Shift;

    if (funct7 == _MExtFunct7.muldiv) {
      final funct3 = InstructionDecoder.extractFunct3(insn);
      final result = _mExt.executeMulDiv(
        funct3: funct3,
        rs1Val: state.regs[rs1],
        rs2Val: state.regs[rs2],
        isWord: false,
      );
      if (rd != 0) _writeReg(rd, result);
      state.pc += instrSize;
      return true;
    }

    if ((funct7 & ~_subFunct7) != 0) {
      _raiseIllegalInsn(insn);
      return false;
    }

    final funct3With30 =
        InstructionDecoder.extractFunct3(insn) |
        ((insn >>> (_bit30Shift - _funct3Width)) & _bit30InFunct3);
    final a = state.regs[rs1];
    final b = state.regs[rs2];

    int val;
    switch (funct3With30) {
      case _RegAluFunct.add:
        val = a + b;
      case _RegAluFunct.sub:
        val = a - b;
      case _RegAluFunct.sll:
        val = a << (b & _shamtMask64);
      case _RegAluFunct.slt:
        val = (a < b) ? 1 : 0;
      case _RegAluFunct.sltu:
        val = _unsignedLessThan(a, b) ? 1 : 0;
      case _RegAluFunct.xor:
        val = a ^ b;
      case _RegAluFunct.srl:
        val = a >>> (b & _shamtMask64);
      case _RegAluFunct.sra:
        val = a >> (b & _shamtMask64);
      case _RegAluFunct.or:
        val = a | b;
      case _RegAluFunct.and:
        val = a & b;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  bool _executeOp32(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct7 = insn >>> _funct7Shift;

    if (funct7 == _MExtFunct7.muldiv) {
      final funct3 = InstructionDecoder.extractFunct3(insn);
      final result = _mExt.executeMulDiv(
        funct3: funct3,
        rs1Val: state.regs[rs1],
        rs2Val: state.regs[rs2],
        isWord: true,
      );
      if (rd != 0) _writeReg(rd, result);
      state.pc += instrSize;
      return true;
    }

    if ((funct7 & ~_subFunct7) != 0) {
      _raiseIllegalInsn(insn);
      return false;
    }

    final funct3With30 =
        InstructionDecoder.extractFunct3(insn) |
        ((insn >>> (_bit30Shift - _funct3Width)) & _bit30InFunct3);
    final a = state.regs[rs1];
    final b = state.regs[rs2];

    int val;
    switch (funct3With30) {
      case _RegAluFunct.add:
        val = BitUtils.signExtend32(a + b);
      case _RegAluFunct.sub:
        val = BitUtils.signExtend32(a - b);
      case _RegAluFunct.sll:
        val = BitUtils.signExtend32((a & _mask32) << (b & _shamtMask32));
      case _RegAluFunct.srl:
        val = BitUtils.signExtend32((a & _mask32) >>> (b & _shamtMask32));
      case _RegAluFunct.sra:
        val = BitUtils.signExtend32(a) >> (b & _shamtMask32);
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  bool _executeSystem(int insn, int instrSize) {
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = insn >>> _immIShift;

    if (funct3 == 0) {
      return _executePrivileged(insn, imm, instrSize);
    }

    return _executeCsr(insn, funct3, imm, instrSize);
  }

  bool _executePrivileged(int insn, int imm, int instrSize) {
    final rs1 = InstructionDecoder.extractRs1(insn);
    switch (imm) {
      case _SystemImm.ecall:
        if (insn & _systemExtraBitsMask != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        state.pendingException = _Exception.userEcall + state.privilege.value;
        return false;

      case _SystemImm.ebreak:
        if (insn & _systemExtraBitsMask != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        state.pendingException = _Exception.breakpoint;
        return false;

      case _SystemImm.sret:
        if (insn & _systemExtraBitsMask != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if (state.privilege.value < PrivilegeLevel.supervisor.value) {
          _raiseIllegalInsn(insn);
          return false;
        }
        exceptionHandler.handleSret();
        return true;

      case _SystemImm.mret:
        if (insn & _systemExtraBitsMask != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if (state.privilege.value < PrivilegeLevel.machine.value) {
          _raiseIllegalInsn(insn);
          return false;
        }
        exceptionHandler.handleMret();
        return true;

      case _SystemImm.wfi:
        if (insn & _wfiExtraBitsMask != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if (state.privilege == PrivilegeLevel.user) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if ((state.mip & state.mie) == 0) {
          state.powerDown = true;
        }
        state.pc += instrSize;
        return true;

      default:
        if ((imm >> _sfenceVmaIdShift) == _sfenceVmaIdValue) {
          if (insn & _wfiExtraBitsMask != 0) {
            _raiseIllegalInsn(insn);
            return false;
          }
          if (state.privilege == PrivilegeLevel.user) {
            _raiseIllegalInsn(insn);
            return false;
          }
          if (rs1 == 0) {
            state.flushTlb();
          } else {
            final vaddr = state.regs[rs1];
            mmu.flushTlbPage(vaddr);
            if ((vaddr & ~TlbConstants.pageMask) == _codePageTag) {
              _invalidateCodeCache();
            }
          }
          state.pc += instrSize;
          return true;
        }
        _raiseIllegalInsn(insn);
        return false;
    }
  }

  bool _executeCsr(int insn, int funct3, int csrAddr, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final isImmediate = (funct3 & _csrImmediateBit) != 0;
    final writeVal = isImmediate ? rs1 : state.regs[rs1];
    final csrOp = funct3 & _csrOpMask;

    try {
      int oldVal;
      switch (csrOp) {
        case _CsrOp.readWrite:
          oldVal = csrHandler.read(csrAddr);
          csrHandler.write(csrAddr, writeVal);
          if (rd != 0) _writeReg(rd, oldVal);

        case _CsrOp.readSet:
          oldVal = csrHandler.read(csrAddr);
          if (rs1 != 0) {
            csrHandler.write(csrAddr, oldVal | writeVal);
          }
          if (rd != 0) _writeReg(rd, oldVal);

        case _CsrOp.readClear:
          oldVal = csrHandler.read(csrAddr);
          if (rs1 != 0) {
            csrHandler.write(csrAddr, oldVal & ~writeVal);
          }
          if (rd != 0) _writeReg(rd, oldVal);

        default:
          _raiseIllegalInsn(insn);
          return false;
      }
    } on CsrAccessException {
      _raiseIllegalInsn(insn);
      return false;
    }

    state.pc += instrSize;
    return true;
  }

  bool _executeMiscMem(int insn, int instrSize) {
    final funct3 = InstructionDecoder.extractFunct3(insn);
    switch (funct3) {
      case _FenceFunct3.fence:
        state.pc += instrSize;
        return true;
      case _FenceFunct3.fenceI:
        _invalidateInstructionCaches();
        state.pc += instrSize;
        return true;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }
  }

  bool _executeAmo(int insn, int instrSize) {
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final funct7 = InstructionDecoder.extractFunct7(insn);
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);

    try {
      _aExt.executeAtomic(
        funct3: funct3,
        funct7: funct7,
        rd: rd,
        rs1Val: state.regs[rs1],
        rs2Val: state.regs[rs2],
        readWord: _amoReadWord,
        readDouble: _amoReadDouble,
        writeWord: _amoWriteWord,
        writeDouble: _amoWriteDouble,
      );
    } on IllegalAtomicException {
      _raiseIllegalInsn(insn);
      return false;
    } on _AmoMemoryFaultException {
      return false;
    }
    state.regs[0] = 0;
    state.pc += instrSize;
    return true;
  }

  int _amoReadWord(int addr) {
    final val = _memReadU32(addr);
    if (state.pendingException >= 0) {
      throw const _AmoMemoryFaultException();
    }
    return BitUtils.signExtend32(val);
  }

  int _amoReadDouble(int addr) {
    final val = _memReadU64(addr);
    if (state.pendingException >= 0) {
      throw const _AmoMemoryFaultException();
    }
    return val;
  }

  void _amoWriteWord(int addr, int value) {
    if (!_memWriteU32(addr, value)) {
      throw const _AmoMemoryFaultException();
    }
  }

  void _amoWriteDouble(int addr, int value) {
    if (!_memWriteU64(addr, value)) {
      throw const _AmoMemoryFaultException();
    }
  }

  bool _fpEnabled() => (state.mstatus & _MstatusFp.fsMask) != 0;

  void _markFsDirty() {
    state.mstatus = (state.mstatus & ~_MstatusFp.fsMask) | _MstatusFp.fsDirty;
  }

  bool _executeLoadFp(int insn, int instrSize) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final addr = state.regs[rs1] + imm;

    switch (funct3) {
      case _FpLoadStoreFunct3.word:
        final val = _memReadU32(addr);
        if (state.pendingException >= 0) return false;
        state.fpRegs.writeWithNanBox(rd, val & _mask32);
      case _FpLoadStoreFunct3.doubleWord:
        final lo = _memReadU32(addr);
        if (state.pendingException >= 0) return false;
        final hi = _memReadU32(addr + _wordSize);
        if (state.pendingException >= 0) return false;
        state.fpRegs.writePair(rd, lo, hi);
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    _markFsDirty();
    state.pc += instrSize;
    return true;
  }

  bool _executeStoreFp(int insn, int instrSize) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmS(insn);
    final addr = state.regs[rs1] + imm;

    switch (funct3) {
      case _FpLoadStoreFunct3.word:
        if (!_memWriteU32(addr, state.fpRegs.readLo(rs2))) {
          return false;
        }
      case _FpLoadStoreFunct3.doubleWord:
        if (!_memWriteU32(addr, state.fpRegs.readLo(rs2))) {
          return false;
        }
        if (!_memWriteU32(addr + _wordSize, state.fpRegs.readHi(rs2))) {
          return false;
        }
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    state.pc += instrSize;
    return true;
  }

  bool _executeFusedMulAdd(int insn, int instrSize, int opcode) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final fmt = (insn >> _fpFmtShift) & _fpFmtMask;

    try {
      switch (fmt) {
        case _FpFmt.single:
          _fExt.executeFusedMulAdd(insn, opcode);
        case _FpFmt.double_:
          _dExt.executeFusedMulAdd(insn, opcode);
        default:
          _raiseIllegalInsn(insn);
          return false;
      }
    } on IllegalFpException {
      _raiseIllegalInsn(insn);
      return false;
    }

    state.pc += instrSize;
    return true;
  }

  bool _executeOpFp(int insn, int instrSize) {
    if (!_fpEnabled()) {
      _raiseIllegalInsn(insn);
      return false;
    }
    final funct7 = insn >>> _funct7Shift;
    final fmt = funct7 & _fpFmtMask;

    try {
      switch (fmt) {
        case _FpFmt.single:
          _fExt.executeArithmetic(insn);
        case _FpFmt.double_:
          _dExt.executeArithmetic(insn);
        default:
          _raiseIllegalInsn(insn);
          return false;
      }
    } on IllegalFpException {
      _raiseIllegalInsn(insn);
      return false;
    }

    state.pc += instrSize;
    return true;
  }

  @pragma('vm:prefer-inline')
  int _memReadU8(int addr) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final pageTag = addr & ~TlbConstants.pageMask;
    final entry = state.tlbRead[tlbIdx];

    if (entry.virtualTag == pageTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      return entry.hostData.getUint8(offset);
    }
    return _memReadSlow(addr, _SizeLog2.byte);
  }

  @pragma('vm:prefer-inline')
  int _memReadU16(int addr) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_halfWordSize - 1));
    final entry = state.tlbRead[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      return entry.hostData.getUint16(offset, Endian.little);
    }
    return _memReadSlow(addr, _SizeLog2.halfWord);
  }

  @pragma('vm:prefer-inline')
  int _memReadU32(int addr) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_wordSize - 1));
    final entry = state.tlbRead[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      return entry.hostData.getUint32(offset, Endian.little);
    }
    return _memReadSlow(addr, _SizeLog2.word);
  }

  @pragma('vm:prefer-inline')
  int _memReadU64(int addr) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_doubleWordSize - 1));
    final entry = state.tlbRead[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      final lo = entry.hostData.getUint32(offset, Endian.little);
      final hi = entry.hostData.getUint32(offset + _wordSize, Endian.little);
      return lo | (hi << _wordBits);
    }
    return _memReadSlow(addr, _SizeLog2.doubleWord);
  }

  int _memReadSlow(int addr, int sizeLog2) {
    final size = 1 << sizeLog2;
    final alignment = addr & (size - 1);
    if (alignment != 0) {
      return _memReadUnaligned(addr, sizeLog2);
    }

    try {
      final physAddr = mmu.translate(addr, MemoryAccessType.read);
      final range = state.memMap.findRange(physAddr);
      if (range == null) return 0;

      if (range is RamRange) {
        _fillReadTlb(addr, physAddr, range);
        return _readFromRam(range, physAddr, sizeLog2);
      }

      if (range is DeviceRange) {
        return _readFromDevice(range, physAddr, sizeLog2);
      }

      return 0;
    } on MmuException catch (e) {
      state
        ..pendingException = e.causeCode
        ..pendingTval = e.virtualAddr;
      return 0;
    }
  }

  int _memReadUnaligned(int addr, int sizeLog2) {
    switch (sizeLog2) {
      case _SizeLog2.halfWord:
        final b0 = _memReadU8(addr);
        if (state.pendingException >= 0) return 0;
        final b1 = _memReadU8(addr + 1);
        if (state.pendingException >= 0) return 0;
        return b0 | (b1 << _bitsPerByte);
      case _SizeLog2.word:
        final aligned = addr & ~(_wordSize - 1);
        final al = addr & (_wordSize - 1);
        final v0 = _memReadU32(aligned);
        if (state.pendingException >= 0) return 0;
        final v1 = _memReadU32(aligned + _wordSize);
        if (state.pendingException >= 0) return 0;
        return ((v0 & _mask32) >>> (al * _bitsPerByte)) |
            ((v1 & _mask32) << (_wordBits - al * _bitsPerByte));
      case _SizeLog2.doubleWord:
        final aligned = addr & ~(_doubleWordSize - 1);
        final al = addr & (_doubleWordSize - 1);
        final v0 = _memReadU64(aligned);
        if (state.pendingException >= 0) return 0;
        final v1 = _memReadU64(aligned + _doubleWordSize);
        if (state.pendingException >= 0) return 0;
        return (v0 >>> (al * _bitsPerByte)) |
            (v1 << (_doubleWordBits - al * _bitsPerByte));
      default:
        return 0;
    }
  }

  void _fillReadTlb(int addr, int physAddr, RamRange range) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final pageOffset = addr & TlbConstants.pageMask;
    final rangeOffset = physAddr - range.addr;
    final pageBase = rangeOffset - pageOffset;

    state.tlbRead[tlbIdx]
      ..virtualTag = addr & ~TlbConstants.pageMask
      ..hostData = range.byteData
      ..hostOffset = pageBase;
  }

  int _readFromRam(RamRange range, int physAddr, int sizeLog2) {
    final offset = physAddr - range.addr;
    return switch (sizeLog2) {
      _SizeLog2.byte => range.byteData.getUint8(offset),
      _SizeLog2.halfWord => range.byteData.getUint16(offset, Endian.little),
      _SizeLog2.word => range.byteData.getUint32(offset, Endian.little),
      _SizeLog2.doubleWord => _readU64FromRange(range, offset),
      _ => 0,
    };
  }

  int _readFromDevice(DeviceRange range, int physAddr, int sizeLog2) {
    final offset = physAddr - range.addr;
    if (sizeLog2 == _SizeLog2.doubleWord) {
      final low = range.readFunc(offset, _SizeLog2.word);
      final high = range.readFunc(offset + _wordSize, _SizeLog2.word);
      return low | (high << _wordBits);
    }
    return range.readFunc(offset, sizeLog2);
  }

  @pragma('vm:prefer-inline')
  bool _memWriteU8(int addr, int val) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final pageTag = addr & ~TlbConstants.pageMask;
    final entry = state.tlbWrite[tlbIdx];

    if (entry.virtualTag == pageTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      entry.hostData.setUint8(offset, val);
      return true;
    }
    return _memWriteSlow(addr, val, _SizeLog2.byte);
  }

  @pragma('vm:prefer-inline')
  bool _memWriteU16(int addr, int val) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_halfWordSize - 1));
    final entry = state.tlbWrite[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      entry.hostData.setUint16(offset, val, Endian.little);
      return true;
    }
    return _memWriteSlow(addr, val, _SizeLog2.halfWord);
  }

  @pragma('vm:prefer-inline')
  bool _memWriteU32(int addr, int val) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_wordSize - 1));
    final entry = state.tlbWrite[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      entry.hostData.setUint32(offset, val, Endian.little);
      return true;
    }
    return _memWriteSlow(addr, val, _SizeLog2.word);
  }

  @pragma('vm:prefer-inline')
  bool _memWriteU64(int addr, int val) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final alignedTag = addr & ~(TlbConstants.pageMask & ~(_doubleWordSize - 1));
    final entry = state.tlbWrite[tlbIdx];

    if (entry.virtualTag == alignedTag) {
      final offset = entry.hostOffset + (addr & TlbConstants.pageMask);
      entry.hostData.setUint32(offset, val & _mask32, Endian.little);
      entry.hostData.setUint32(
        offset + _wordSize,
        (val >> _wordBits) & _mask32,
        Endian.little,
      );
      return true;
    }
    return _memWriteSlow(addr, val, _SizeLog2.doubleWord);
  }

  bool _memWriteSlow(int addr, int val, int sizeLog2) {
    final size = 1 << sizeLog2;
    final alignment = addr & (size - 1);
    if (alignment != 0) {
      return _memWriteUnaligned(addr, val, sizeLog2);
    }

    try {
      final physAddr = mmu.translate(addr, MemoryAccessType.write);
      final range = state.memMap.findRange(physAddr);
      if (range == null) return true;

      if (range is RamRange) {
        _fillWriteTlb(addr, physAddr, range);
        _writeToRam(range, physAddr, val, sizeLog2);
        return true;
      }

      if (range is DeviceRange) {
        _writeToDevice(range, physAddr, val, sizeLog2);
        return true;
      }

      return true;
    } on MmuException catch (e) {
      state
        ..pendingException = e.causeCode
        ..pendingTval = e.virtualAddr;
      return false;
    }
  }

  bool _memWriteUnaligned(int addr, int val, int sizeLog2) {
    final size = 1 << sizeLog2;
    for (var i = 0; i < size; i++) {
      if (!_memWriteU8(addr + i, (val >> (i * _bitsPerByte)) & _byteMask)) {
        return false;
      }
    }
    return true;
  }

  void _fillWriteTlb(int addr, int physAddr, RamRange range) {
    final tlbIdx =
        (addr >>> TlbConstants.pageSizeLog2) & TlbConstants.indexMask;
    final pageOffset = addr & TlbConstants.pageMask;
    final rangeOffset = physAddr - range.addr;
    final pageBase = rangeOffset - pageOffset;

    range.dirtyBits.set((physAddr - range.addr) >> TlbConstants.pageSizeLog2);

    state.tlbWrite[tlbIdx]
      ..virtualTag = addr & ~TlbConstants.pageMask
      ..hostData = range.byteData
      ..hostOffset = pageBase;

    _onGuestStorePage(range.byteData, pageBase);
  }

  /// Called when a guest store targets ([data], [pageBase]) for the
  /// first time since that page's write-TLB entry was purged.
  void _onGuestStorePage(ByteData data, int pageBase) {
    _dropDecodedPage(data, pageBase);
  }

  void _writeToRam(RamRange range, int physAddr, int val, int sizeLog2) {
    final offset = physAddr - range.addr;
    switch (sizeLog2) {
      case _SizeLog2.byte:
        range.byteData.setUint8(offset, val);
      case _SizeLog2.halfWord:
        range.byteData.setUint16(offset, val, Endian.little);
      case _SizeLog2.word:
        range.byteData.setUint32(offset, val, Endian.little);
      case _SizeLog2.doubleWord:
        _writeU64ToRange(range, offset, val);
    }
  }

  static int _readU64FromRange(RamRange range, int offset) {
    final lo = range.byteData.getUint32(offset, Endian.little);
    final hi = range.byteData.getUint32(offset + _wordSize, Endian.little);
    return lo | (hi << _wordBits);
  }

  static void _writeU64ToRange(RamRange range, int offset, int val) {
    range.byteData.setUint32(offset, val & _mask32, Endian.little);
    range.byteData.setUint32(
      offset + _wordSize,
      (val >> _wordBits) & _mask32,
      Endian.little,
    );
  }

  void _writeToDevice(DeviceRange range, int physAddr, int val, int sizeLog2) {
    final offset = physAddr - range.addr;
    if (sizeLog2 == _SizeLog2.doubleWord) {
      range.writeFunc(offset, val & _mask32, _SizeLog2.word);
      range.writeFunc(
        offset + _wordSize,
        (val >>> _wordBits) & _mask32,
        _SizeLog2.word,
      );
      return;
    }
    range.writeFunc(offset, val, sizeLog2);
  }

  void _writeReg(int rd, int value) {
    if (rd != 0) state.regs[rd] = value;
  }

  void _raiseIllegalInsn(int insn) {
    state
      ..pendingException = _Exception.illegalInstruction
      ..pendingTval = insn;
  }

  bool _unsignedLessThan(int a, int b) =>
      (a ^ state.signBit) < (b ^ state.signBit);

  int _signExtend8(int value) {
    final masked = value & _byteMask;
    if ((masked & _byteMsb) != 0) {
      return masked | ~_byteMask;
    }
    return masked;
  }

  int _signExtend16(int value) {
    final masked = value & _halfWordMask;
    if ((masked & _halfWordMsb) != 0) {
      return masked | ~_halfWordMask;
    }
    return masked;
  }

  int _cField(int insn, int srcPos, int dstPos, int dstPosMax) {
    final width = dstPosMax - dstPos + 1;
    final mask = ((1 << width) - 1) << dstPos;
    if (dstPos >= srcPos) {
      return (insn << (dstPos - srcPos)) & mask;
    }
    return (insn >>> (srcPos - dstPos)) & mask;
  }

  int _cSignExtend(int value, int bits) {
    final signBitVal = 1 << (bits - 1);
    return (value ^ signBitVal) - signBitVal;
  }

  int _cJImm(int insn) => _cSignExtend(
    _cField(insn, 12, 11, 11) |
        _cField(insn, 11, 4, 4) |
        _cField(insn, 9, 8, 9) |
        _cField(insn, 8, 10, 10) |
        _cField(insn, 7, 6, 6) |
        _cField(insn, 6, 7, 7) |
        _cField(insn, 3, 1, 3) |
        _cField(insn, 2, 5, 5),
    12,
  );

  int _cBranchImm(int insn) => _cSignExtend(
    _cField(insn, 12, 8, 8) |
        _cField(insn, 10, 3, 4) |
        _cField(insn, 5, 6, 7) |
        _cField(insn, 3, 1, 2) |
        _cField(insn, 2, 5, 5),
    9,
  );

  void _initMisa() {
    state
      ..misa =
          _IsaBits.i |
          _IsaBits.m |
          _IsaBits.a |
          _IsaBits.c |
          _IsaBits.f |
          _IsaBits.d |
          _IsaBits.s |
          _IsaBits.u |
          (_mxlRv64 << _mxlShift64)
      ..mxl = _mxlRv64
      ..curXlen = state.xlen.value
      ..mstatus = (_mxlRv64 << _uxlShift) | (_mxlRv64 << _sxlShift);
  }

  static const _isaExtBits =
      _IsaBits.i |
      _IsaBits.m |
      _IsaBits.a |
      _IsaBits.c |
      _IsaBits.f |
      _IsaBits.d |
      _IsaBits.s |
      _IsaBits.u;
  static const _mxlRv32 = 1;
  static const _mxlRv64 = 2;
  static const _mxlShift32 = 30;
  static const _mxlShift64 = 62;
  static const _uxlShift = 32;
  static const _sxlShift = 34;

  static const _noPendingException = -1;
  static const _compressedInsnSize = 2;
  static const _fullInsnSize = 4;
  static const _compressedMask = 0x03;
  static const _halfWordBits = 16;
  static const _opcodeMask = 0x7F;
  static const _regMask = 0x1F;
  static const _raReg = 1;
  static const _funct7Shift = 25;
  static const _immIShift = 20;
  static const _immUMask = 0xFFFFF000;
  static const _cFunct3Shift = 13;
  static const _cFunct3Mask = 0x07;

  static const _shamtMask64 = 63;
  static const _shamtMask32 = 31;
  static const _cShiftBit5 = 0x20;
  static const _sraBit = 0x400;
  static const _subFunct7 = 0x20;
  static const _funct3Width = 3;
  static const _bit30Shift = 30;
  static const _bit30InFunct3 = 1 << 3;

  static const _mask32 = 0xFFFFFFFF;
  static const _byteMask = 0xFF;
  static const _byteMsb = 0x80;
  static const _halfWordMask = 0xFFFF;
  static const _halfWordMsb = 0x8000;
  static const _bitsPerByte = 8;
  static const _wordBits = 32;
  static const _doubleWordBits = 64;
  static const _wordSize = 4;
  static const _halfWordSize = 2;
  static const _doubleWordSize = 8;

  static const _csrImmediateBit = 4;
  static const _csrOpMask = 3;

  static const _systemExtraBitsMask = 0x000FFF80;
  static const _wfiExtraBitsMask = 0x00007F80;
  static const _sfenceVmaIdShift = 5;
  static const _sfenceVmaIdValue = 0x09;
  static const _fpFmtShift = 25;
  static const _fpFmtMask = 0x03;
}

class _CpuExecutor64 extends CpuExecutor {
  _CpuExecutor64({required super.memMap}) : super._(xlen: Xlen.rv64);

  static const _countPairs = bool.fromEnvironment('DARTEMU_COUNT_PAIRS');

  /// Dynamic (previous op, current op) pair frequencies; only populated
  /// when compiled with -DDARTEMU_COUNT_PAIRS=true.
  static final Int64List pairCounts = Int64List(1 << 16);
  static int _prevOp = 0;

  /// Predecoded dispatch loop.
  ///
  /// Executes micro-ops from the [DecodedPage] paired with the current
  /// code page: no per-instruction fetch, field extraction, or nested
  /// opcode dispatch. Uncommon instructions (FP, atomics, system,
  /// page-crossing fetches) fall back to the classic interpreter path.
  /// Cycle accounting mirrors [CpuExecutor.execute] exactly.
  @override
  void execute(int maxCycles) {
    if (maxCycles <= 0) return;

    final counterTarget = state.instructionCounter + maxCycles;
    state.nCycles = maxCycles;

    if (_hasPendingInterrupt()) {
      _handleInterrupt();
      state.nCycles--;
      _syncCounter(counterTarget);
      return;
    }

    state.pendingException = CpuExecutor._noPendingException;

    var pc = state.pc;
    var cycles = state.nCycles;

    final regs = state.regs as Int64List;
    final signBit = state.signBit;
    var page = _decodedPage ?? CpuExecutor._sentinelPage;
    var metas = page.meta;
    var imms = page.imm;

    while (cycles > 0) {
      if (_hasPendingInterrupt()) {
        state.pc = pc;
        state.nCycles = cycles;
        _handleInterrupt();
        state.nCycles--;
        _syncCounter(counterTarget);
        return;
      }

      final addr = pc;
      if ((addr & ~TlbConstants.pageMask) != _codePageTag) {
        _fetchSlowAndCache(addr);
        if (state.pendingException >= 0) {
          state.pc = pc;
          state.nCycles = cycles;
          _handlePendingException(counterTarget);
          return;
        }
        page = _decodedPage!;
        metas = page.meta;
        imms = page.imm;
        continue;
      }

      final slot = (addr & TlbConstants.pageMask) >> 1;
      var m = metas[slot];
      if ((m & PredecodeMeta.opMask) == PredecodeOp.undecoded) {
        m = Rv64Predecoder.decodeSlot(page, slot);
      }

      cycles--;

      if (_countPairs) {
        pairCounts[(_prevOp << 8) | (m & PredecodeMeta.opMask)]++;
        _prevOp = m & PredecodeMeta.opMask;
      }

      switch (m & PredecodeMeta.opMask) {
        case PredecodeOp.nop:
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.addi:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.add:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sub:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] -
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.and:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.or:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] |
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.xor:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.andi:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.ori:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] |
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.xori:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slli:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <<
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srli:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>>
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srai:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sll:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <<
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask64);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srl:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>>
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask64);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sra:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask64);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slt:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sltu:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
                      signBit) <
                  (regs[(m >>> PredecodeMeta.rs2Shift) &
                          PredecodeMeta.regMask] ^
                      signBit)
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slti:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  imms[slot]
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sltiu:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
                      signBit) <
                  (imms[slot] ^ signBit)
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.addiw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.addw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.subw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] -
                regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slliw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <<
                imms[slot],
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srliw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
                    CpuExecutor._mask32) >>>
                imms[slot],
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sraiw:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              BitUtils.signExtend32(
                regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask],
              ) >>
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sllw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
                    CpuExecutor._mask32) <<
                (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                    CpuExecutor._shamtMask32),
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srlw:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = BitUtils.signExtend32(
            (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
                    CpuExecutor._mask32) >>>
                (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                    CpuExecutor._shamtMask32),
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sraw:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              BitUtils.signExtend32(
                regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask],
              ) >>
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask32);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lui:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.auipc:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.jal:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));
          pc = addr + imms[slot];

        case PredecodeOp.j:
          pc = addr + imms[slot];

        case PredecodeOp.jalr:
          final target =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                  imms[slot]) &
              ~1;
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));
          pc = target;

        case PredecodeOp.jr:
          pc =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                  imms[slot]) &
              ~1;

        case PredecodeOp.beq:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ==
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bne:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] !=
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.blt:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bge:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >=
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bltu:
          pc =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
                      signBit) <
                  (regs[(m >>> PredecodeMeta.rs2Shift) &
                          PredecodeMeta.regMask] ^
                      signBit)
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bgeu:
          pc =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
                      signBit) >=
                  (regs[(m >>> PredecodeMeta.rs2Shift) &
                          PredecodeMeta.regMask] ^
                      signBit)
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.ld:
          final val = _memReadU64(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lw:
          final val = _memReadU32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              BitUtils.signExtend32(val);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lwu:
          final val = _memReadU32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              val & CpuExecutor._mask32;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lh:
          final val = _memReadU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              _signExtend16(val);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lhu:
          final val = _memReadU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lb:
          final val = _memReadU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              _signExtend8(val);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lbu:
          final val = _memReadU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sd:
          if (!_memWriteU64(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sw:
          if (!_memWriteU32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sh:
          if (!_memWriteU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sb:
          if (!_memWriteU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.mulDiv:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = _mExt.executeMulDiv(
            funct3: imms[slot],
            rs1Val:
                regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask],
            rs2Val:
                regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
            isWord: false,
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.mulDivW:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = _mExt.executeMulDiv(
            funct3: imms[slot],
            rs1Val:
                regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask],
            rs2Val:
                regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
            isWord: true,
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        default:
          state.pc = pc;
          state.nCycles = cycles;
          final insn = _fetchInstruction();
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          final size = InstructionDecoder.isCompressed(insn)
              ? CpuExecutor._compressedInsnSize
              : CpuExecutor._fullInsnSize;
          if (!_executeInstruction(insn, size)) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = state.pc;
          page = _decodedPage ?? CpuExecutor._sentinelPage;
          metas = page.meta;
          imms = page.imm;
      }

      if (state.powerDown) break;
    }

    state.pc = pc;
    state.nCycles = cycles;
    _syncCounter(counterTarget);
  }

  @override
  bool _executeInstruction(int insn, int instrSize) {
    final opcode = insn & CpuExecutor._opcodeMask;

    switch (opcode) {
      case _Opcode.load:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _LoadFunct3.ld) {
          final rd = (insn >> 7) & CpuExecutor._regMask;
          final rs1 = (insn >> 15) & CpuExecutor._regMask;
          final imm = InstructionDecoder.extractImmI(insn);
          final addr = state.regs[rs1] + imm;
          final val = _memReadU64(addr);
          if (state.pendingException >= 0) return false;
          if (rd != 0) state.regs[rd] = val;
          state.pc += instrSize;
          return true;
        }
        return _executeLoad(insn, instrSize);
      case _Opcode.store:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _StoreFunct3.sd) {
          final rs1 = (insn >> 15) & CpuExecutor._regMask;
          final rs2 = (insn >> 20) & CpuExecutor._regMask;
          final imm = InstructionDecoder.extractImmS(insn);
          final addr = state.regs[rs1] + imm;
          if (!_memWriteU64(addr, state.regs[rs2])) {
            return false;
          }
          state.pc += instrSize;
          return true;
        }
        return _executeStore(insn, instrSize);
      case _Opcode.opImm:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _AluFunct3.add) {
          final rd = (insn >> 7) & CpuExecutor._regMask;
          if (rd != 0) {
            final rs1 = (insn >> 15) & CpuExecutor._regMask;
            final imm = InstructionDecoder.extractImmI(insn);
            state.regs[rd] = state.regs[rs1] + imm;
          }
          state.pc += instrSize;
          return true;
        }
        return _executeOpImm(insn, instrSize);
      default:
        return super._executeInstruction(insn, instrSize);
    }
  }
}

class _CpuExecutor32 extends CpuExecutor {
  _CpuExecutor32({required super.memMap}) : super._(xlen: Xlen.rv32);

  static const _xlenBits = 32;

  /// Predecoded dispatch loop (RV32).
  ///
  /// Mirrors the RV64 loop with RV32 semantics: registers live in a
  /// Uint32List whose stores truncate to 32 bits, signed comparisons
  /// go through toSigned(32), and unsigned comparisons operate on the
  /// already-unsigned register values. Every case body uses the same
  /// expressions as the classic RV32 handlers, so web numeric
  /// behaviour is identical by construction.
  @override
  void execute(int maxCycles) {
    if (maxCycles <= 0) return;

    final counterTarget = state.instructionCounter + maxCycles;
    state.nCycles = maxCycles;

    if (_hasPendingInterrupt()) {
      _handleInterrupt();
      state.nCycles--;
      _syncCounter(counterTarget);
      return;
    }

    state.pendingException = CpuExecutor._noPendingException;

    var pc = state.pc;
    var cycles = state.nCycles;
    final regs = state.regs as Uint32List;
    var page = _decodedPage ?? CpuExecutor._sentinelPage;
    var metas = page.meta;
    var imms = page.imm;

    while (cycles > 0) {
      if (_hasPendingInterrupt()) {
        state.pc = pc;
        state.nCycles = cycles;
        _handleInterrupt();
        state.nCycles--;
        _syncCounter(counterTarget);
        return;
      }

      final addr = pc;
      if ((addr & ~TlbConstants.pageMask) != _codePageTag) {
        _fetchSlowAndCache(addr);
        if (state.pendingException >= 0) {
          state.pc = pc;
          state.nCycles = cycles;
          _handlePendingException(counterTarget);
          return;
        }
        page = _decodedPage!;
        metas = page.meta;
        imms = page.imm;
        continue;
      }

      final slot = (addr & TlbConstants.pageMask) >> 1;
      var m = metas[slot];
      if ((m & PredecodeMeta.opMask) == PredecodeOp.undecoded) {
        m = Rv32Predecoder.decodeSlot(page, slot);
      }

      cycles--;

      switch (m & PredecodeMeta.opMask) {
        case PredecodeOp.nop:
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.addi:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.add:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sub:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] -
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.and:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.or:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] |
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.xor:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
              regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.andi:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] &
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.ori:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] |
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.xori:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ^
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slli:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <<
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srli:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>>
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srai:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                  .toSigned(_xlenBits) >>
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sll:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <<
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask32);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.srl:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >>>
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask32);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sra:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                  .toSigned(_xlenBits) >>
              (regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask] &
                  CpuExecutor._shamtMask32);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slt:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits) <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits)
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sltu:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.slti:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits) <
                  imms[slot]
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sltiu:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  (imms[slot] & CpuExecutor._mask32)
              ? 1
              : 0;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lui:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.auipc:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + imms[slot];
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.jal:
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));
          pc = addr + imms[slot];

        case PredecodeOp.j:
          pc = addr + imms[slot];

        case PredecodeOp.jalr:
          final target =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                  imms[slot]) &
              ~1;
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));
          pc = target;

        case PredecodeOp.jr:
          pc =
              (regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                  imms[slot]) &
              ~1;

        case PredecodeOp.beq:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] ==
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bne:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] !=
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.blt:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits) <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits)
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bge:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits) >=
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
                      .toSigned(_xlenBits)
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bltu:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] <
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.bgeu:
          pc =
              regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] >=
                  regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask]
              ? addr + imms[slot]
              : addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lw:
          final val = _memReadU32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lh:
          final val = _memReadU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              _signExtend16(val);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lhu:
          final val = _memReadU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lb:
          final val = _memReadU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] =
              _signExtend8(val);
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.lbu:
          final val = _memReadU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
          );
          if (state.pendingException >= 0) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          regs[(m >>> PredecodeMeta.rdShift) & PredecodeMeta.regMask] = val;
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sw:
          if (!_memWriteU32(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sh:
          if (!_memWriteU16(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.sb:
          if (!_memWriteU8(
            regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask] +
                imms[slot],
            regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
          )) {
            state.pc = pc;
            state.nCycles = cycles;
            _handlePendingException(counterTarget);
            return;
          }
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        case PredecodeOp.mulDiv:
          regs[(m >>> PredecodeMeta.rdShift) &
              PredecodeMeta.regMask] = _mExt.executeMulDiv(
            funct3: imms[slot],
            rs1Val:
                regs[(m >>> PredecodeMeta.rs1Shift) & PredecodeMeta.regMask],
            rs2Val:
                regs[(m >>> PredecodeMeta.rs2Shift) & PredecodeMeta.regMask],
            isWord: false,
          );
          pc = addr + (2 << ((m >>> PredecodeMeta.sizeShift) & 1));

        default:
          state.pc = pc;
          state.nCycles = cycles;
          final insn = _fetchInstruction();
          if (state.pendingException >= 0) {
            _handlePendingException(counterTarget);
            return;
          }
          final size = InstructionDecoder.isCompressed(insn)
              ? CpuExecutor._compressedInsnSize
              : CpuExecutor._fullInsnSize;
          if (!_executeInstruction(insn, size)) {
            _handlePendingException(counterTarget);
            return;
          }
          pc = state.pc;
          page = _decodedPage ?? CpuExecutor._sentinelPage;
          metas = page.meta;
          imms = page.imm;
      }

      if (state.powerDown) break;
    }

    state.pc = pc;
    state.nCycles = cycles;
    _syncCounter(counterTarget);
  }

  @override
  bool _executeInstruction(int insn, int instrSize) {
    final opcode = insn & CpuExecutor._opcodeMask;

    switch (opcode) {
      case _Opcode.lui:
        final rd = (insn >> 7) & CpuExecutor._regMask;
        if (rd != 0) {
          state.regs[rd] = BitUtils.signExtend32(insn & CpuExecutor._immUMask);
        }
        state.pc += instrSize;
        return true;
      case _Opcode.auipc:
        final rd = (insn >> 7) & CpuExecutor._regMask;
        if (rd != 0) {
          state.regs[rd] =
              state.pc + BitUtils.signExtend32(insn & CpuExecutor._immUMask);
        }
        state.pc += instrSize;
        return true;
      case _Opcode.jal:
        final rd = (insn >> 7) & CpuExecutor._regMask;
        if (rd != 0) {
          state.regs[rd] = state.pc + CpuExecutor._fullInsnSize;
        }
        state.pc += InstructionDecoder.extractImmJ(insn);
        return true;
      case _Opcode.jalr:
        final rd = (insn >> 7) & CpuExecutor._regMask;
        final rs1 = (insn >> 15) & CpuExecutor._regMask;
        final imm = InstructionDecoder.extractImmI(insn);
        final returnAddr = state.pc + CpuExecutor._fullInsnSize;
        state.pc = (state.regs[rs1] + imm) & ~1;
        if (rd != 0) state.regs[rd] = returnAddr;
        return true;
      case _Opcode.branch:
        final funct3 = (insn >> 12) & 7;
        if (funct3 <= 1) {
          final rs1 = (insn >> 15) & CpuExecutor._regMask;
          final rs2 = (insn >> 20) & CpuExecutor._regMask;
          final eq = state.regs[rs1] == state.regs[rs2];
          final taken = funct3 == 0 ? eq : !eq;
          if (taken) {
            state.pc += InstructionDecoder.extractImmB(insn);
          } else {
            state.pc += instrSize;
          }
          return true;
        }
        return _executeBranch(insn, instrSize);
      case _Opcode.load:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _LoadFunct3.lw) {
          final rd = (insn >> 7) & CpuExecutor._regMask;
          final rs1 = (insn >> 15) & CpuExecutor._regMask;
          final imm = InstructionDecoder.extractImmI(insn);
          final addr = state.regs[rs1] + imm;
          final val = _memReadU32(addr);
          if (state.pendingException >= 0) return false;
          if (rd != 0) state.regs[rd] = val;
          state.pc += instrSize;
          return true;
        }
        return _executeLoad(insn, instrSize);
      case _Opcode.store:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _StoreFunct3.sw) {
          final rs1 = (insn >> 15) & CpuExecutor._regMask;
          final rs2 = (insn >> 20) & CpuExecutor._regMask;
          final imm = InstructionDecoder.extractImmS(insn);
          final addr = state.regs[rs1] + imm;
          if (!_memWriteU32(addr, state.regs[rs2])) {
            return false;
          }
          state.pc += instrSize;
          return true;
        }
        return _executeStore(insn, instrSize);
      case _Opcode.opImm:
        final funct3 = (insn >> 12) & 7;
        if (funct3 == _AluFunct3.add) {
          final rd = (insn >> 7) & CpuExecutor._regMask;
          if (rd != 0) {
            final rs1 = (insn >> 15) & CpuExecutor._regMask;
            final imm = InstructionDecoder.extractImmI(insn);
            state.regs[rd] = state.regs[rs1] + imm;
          }
          state.pc += instrSize;
          return true;
        }
        return _executeOpImm(insn, instrSize);
      default:
        return super._executeInstruction(insn, instrSize);
    }
  }

  @override
  void _initMisa() {
    state
      ..misa =
          CpuExecutor._isaExtBits |
          (CpuExecutor._mxlRv32 << CpuExecutor._mxlShift32)
      ..mxl = CpuExecutor._mxlRv32
      ..curXlen = state.xlen.value;
  }

  @override
  bool _unsignedLessThan(int a, int b) =>
      (a & CpuExecutor._mask32) < (b & CpuExecutor._mask32);

  @override
  bool _executeBranch(int insn, int instrSize) {
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final a = state.regs[rs1];
    final b = state.regs[rs2];

    bool condition;
    switch (funct3 >> 1) {
      case 0:
        condition = a == b;
      case 2:
        condition = a.toSigned(_xlenBits) < b.toSigned(_xlenBits);
      case 3:
        condition = _unsignedLessThan(a, b);
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if ((funct3 & 1) != 0) condition = !condition;

    if (condition) {
      final imm = InstructionDecoder.extractImmB(insn);
      state.pc += imm;
    } else {
      state.pc += instrSize;
    }
    return true;
  }

  @override
  bool _executeLoad(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final addr = state.regs[rs1] + imm;

    int val;
    switch (funct3) {
      case _LoadFunct3.lb:
        val = _memReadU8(addr);
        if (state.pendingException >= 0) return false;
        val = _signExtend8(val);
      case _LoadFunct3.lh:
        val = _memReadU16(addr);
        if (state.pendingException >= 0) return false;
        val = _signExtend16(val);
      case _LoadFunct3.lw:
        val = _memReadU32(addr);
        if (state.pendingException >= 0) return false;
      case _LoadFunct3.lbu:
        val = _memReadU8(addr);
        if (state.pendingException >= 0) return false;
      case _LoadFunct3.lhu:
        val = _memReadU16(addr);
        if (state.pendingException >= 0) return false;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  @override
  bool _executeStore(int insn, int instrSize) {
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmS(insn);
    final addr = state.regs[rs1] + imm;
    final val = state.regs[rs2];

    switch (funct3) {
      case _StoreFunct3.sb:
        if (!_memWriteU8(addr, val)) return false;
      case _StoreFunct3.sh:
        if (!_memWriteU16(addr, val)) return false;
      case _StoreFunct3.sw:
        if (!_memWriteU32(addr, val)) return false;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    state.pc += instrSize;
    return true;
  }

  @override
  bool _executeOpImm(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final funct3 = InstructionDecoder.extractFunct3(insn);
    final imm = InstructionDecoder.extractImmI(insn);
    final src = state.regs[rs1];

    int val;
    switch (funct3) {
      case _AluFunct3.add:
        val = src + imm;
      case _AluFunct3.sll:
        if ((imm & ~CpuExecutor._shamtMask32) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        val = src << (imm & CpuExecutor._shamtMask32);
      case _AluFunct3.slt:
        val = (src.toSigned(_xlenBits) < imm.toSigned(_xlenBits)) ? 1 : 0;
      case _AluFunct3.sltu:
        val = _unsignedLessThan(src, imm) ? 1 : 0;
      case _AluFunct3.xor:
        val = src ^ imm;
      case _AluFunct3.srl:
        final shamtBits = imm & CpuExecutor._shamtMask32;
        if ((imm & ~(CpuExecutor._shamtMask32 | CpuExecutor._sraBit)) != 0) {
          _raiseIllegalInsn(insn);
          return false;
        }
        if ((imm & CpuExecutor._sraBit) != 0) {
          val = src.toSigned(_xlenBits) >> shamtBits;
        } else {
          val = src >>> shamtBits;
        }
      case _AluFunct3.or:
        val = src | imm;
      case _AluFunct3.and:
        val = src & imm;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  @override
  bool _executeOpImm32(int insn, int instrSize) {
    _raiseIllegalInsn(insn);
    return false;
  }

  @override
  bool _executeOp(int insn, int instrSize) {
    final rd = InstructionDecoder.extractRd(insn);
    final rs1 = InstructionDecoder.extractRs1(insn);
    final rs2 = InstructionDecoder.extractRs2(insn);
    final funct7 = insn >>> CpuExecutor._funct7Shift;

    if (funct7 == _MExtFunct7.muldiv) {
      final funct3 = InstructionDecoder.extractFunct3(insn);
      final result = _mExt.executeMulDiv(
        funct3: funct3,
        rs1Val: state.regs[rs1],
        rs2Val: state.regs[rs2],
        isWord: false,
      );
      if (rd != 0) _writeReg(rd, result);
      state.pc += instrSize;
      return true;
    }

    if ((funct7 & ~CpuExecutor._subFunct7) != 0) {
      _raiseIllegalInsn(insn);
      return false;
    }

    final funct3With30 =
        InstructionDecoder.extractFunct3(insn) |
        ((insn >>> (CpuExecutor._bit30Shift - CpuExecutor._funct3Width)) &
            CpuExecutor._bit30InFunct3);
    final a = state.regs[rs1];
    final b = state.regs[rs2];

    int val;
    switch (funct3With30) {
      case _RegAluFunct.add:
        val = a + b;
      case _RegAluFunct.sub:
        val = a - b;
      case _RegAluFunct.sll:
        val = a << (b & CpuExecutor._shamtMask32);
      case _RegAluFunct.slt:
        val = (a.toSigned(_xlenBits) < b.toSigned(_xlenBits)) ? 1 : 0;
      case _RegAluFunct.sltu:
        val = _unsignedLessThan(a, b) ? 1 : 0;
      case _RegAluFunct.xor:
        val = a ^ b;
      case _RegAluFunct.srl:
        val = a >>> (b & CpuExecutor._shamtMask32);
      case _RegAluFunct.sra:
        val = a.toSigned(_xlenBits) >> (b & CpuExecutor._shamtMask32);
      case _RegAluFunct.or:
        val = a | b;
      case _RegAluFunct.and:
        val = a & b;
      default:
        _raiseIllegalInsn(insn);
        return false;
    }

    if (rd != 0) _writeReg(rd, val);
    state.pc += instrSize;
    return true;
  }

  @override
  bool _executeOp32(int insn, int instrSize) {
    _raiseIllegalInsn(insn);
    return false;
  }

  @override
  bool _executeCompressedQ0(int insn, int funct3) {
    final rdPrime = ((insn >> 2) & 7) | 8;

    return switch (funct3) {
      0 => _cAddi4spn(insn, rdPrime),
      1 => _cFld(insn, rdPrime),
      2 => _cLw(insn, rdPrime),
      3 => _cFlw(insn, rdPrime),
      5 => _cFsd(insn, rdPrime),
      6 => _cSw(insn, rdPrime),
      7 => _cFsw(insn, rdPrime),
      _ => _illegalCompressed(insn),
    };
  }

  @override
  bool _executeCompressedQ1(int insn, int funct3) => switch (funct3) {
    0 => _cAddiNop(insn),
    1 => _cJal(insn),
    2 => _cLi(insn),
    3 => _cLuiAddi16sp(insn),
    4 => _cArith(insn),
    5 => _cJ(insn),
    6 => _cBeqz(insn),
    7 => _cBnez(insn),
    _ => _illegalCompressed(insn),
  };

  @override
  bool _executeCompressedQ2(int insn, int funct3) {
    final rs2 = (insn >> 2) & CpuExecutor._regMask;

    return switch (funct3) {
      0 => _cSlli(insn, rs2),
      1 => _cFldsp(insn),
      2 => _cLwsp(insn, rs2),
      3 => _cFlwsp(insn, rs2),
      4 => _cJrMvAddEbreak(insn, rs2),
      5 => _cFsdsp(insn, rs2),
      6 => _cSwsp(insn, rs2),
      7 => _cFswsp(insn, rs2),
      _ => _illegalCompressed(insn),
    };
  }

  @override
  bool _cShift(int insn, int rd, int isArith) {
    final imm = _cField(insn, 12, 5, 5) | _cField(insn, 2, 0, 4);
    if ((imm & CpuExecutor._cShiftBit5) != 0) {
      _raiseIllegalInsn(insn);
      return false;
    }
    if (isArith == 0) {
      _writeReg(rd, state.regs[rd] >>> imm);
    } else {
      _writeReg(rd, state.regs[rd].toSigned(_xlenBits) >> imm);
    }
    state.pc += CpuExecutor._compressedInsnSize;
    return true;
  }

  @override
  bool _cSlli(int insn, int rs2) {
    final rd = InstructionDecoder.extractRd(insn);
    final imm = _cField(insn, 12, 5, 5) | rs2;
    if ((imm & CpuExecutor._cShiftBit5) != 0) {
      _raiseIllegalInsn(insn);
      return false;
    }
    if (rd != 0) {
      _writeReg(rd, state.regs[rd] << imm);
    }
    state.pc += CpuExecutor._compressedInsnSize;
    return true;
  }

  @override
  bool _cRegArith(int insn, int rd) {
    final rs2 = ((insn >> 2) & 7) | 8;
    final subOp = ((insn >> 5) & 3) | ((insn >> (12 - 2)) & 4);

    switch (subOp) {
      case 0:
        _writeReg(rd, state.regs[rd] - state.regs[rs2]);
      case 1:
        _writeReg(rd, state.regs[rd] ^ state.regs[rs2]);
      case 2:
        _writeReg(rd, state.regs[rd] | state.regs[rs2]);
      case 3:
        _writeReg(rd, state.regs[rd] & state.regs[rs2]);
      default:
        _raiseIllegalInsn(insn);
        return false;
    }
    state.pc += CpuExecutor._compressedInsnSize;
    return true;
  }
}

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
  static const system = 0x73;
  static const miscMem = 0x0F;
  static const amo = 0x2F;
  static const loadFp = 0x07;
  static const storeFp = 0x27;
  static const fmadd = 0x43;
  static const fmsub = 0x47;
  static const fnmsub = 0x4B;
  static const fnmadd = 0x4F;
  static const opFp = 0x53;
}

class _LoadFunct3 {
  static const lb = 0;
  static const lh = 1;
  static const lw = 2;
  static const ld = 3;
  static const lbu = 4;
  static const lhu = 5;
  static const lwu = 6;
}

class _StoreFunct3 {
  static const sb = 0;
  static const sh = 1;
  static const sw = 2;
  static const sd = 3;
}

class _AluFunct3 {
  static const add = 0;
  static const sll = 1;
  static const slt = 2;
  static const sltu = 3;
  static const xor = 4;
  static const srl = 5;
  static const or = 6;
  static const and = 7;
}

class _RegAluFunct {
  static const add = 0;
  static const sub = 0 | 8;
  static const sll = 1;
  static const slt = 2;
  static const sltu = 3;
  static const xor = 4;
  static const srl = 5;
  static const sra = 5 | 8;
  static const or = 6;
  static const and = 7;
}

class _MExtFunct7 {
  static const muldiv = 1;
}

class _CsrOp {
  static const readWrite = 1;
  static const readSet = 2;
  static const readClear = 3;
}

class _FenceFunct3 {
  static const fence = 0;
  static const fenceI = 1;
}

class _SystemImm {
  static const ecall = 0x000;
  static const ebreak = 0x001;
  static const sret = 0x102;
  static const mret = 0x302;
  static const wfi = 0x105;
}

class _Exception {
  static const faultFetch = 0x1;
  static const illegalInstruction = 0x2;
  static const breakpoint = 0x3;
  static const userEcall = 0x8;
}

class _SizeLog2 {
  static const byte = 0;
  static const halfWord = 1;
  static const word = 2;
  static const doubleWord = 3;
}

class _IsaBits {
  static const i = 1 << 8;
  static const m = 1 << 12;
  static const a = 1 << 0;
  static const c = 1 << 2;
  static const f = 1 << 5;
  static const d = 1 << 3;
  static const s = 1 << 18;
  static const u = 1 << 20;
}

class _MstatusFp {
  static const fsMask = 0x6000;
  static const fsDirty = 0x6000;
}

class _FpLoadStoreFunct3 {
  static const word = 2;
  static const doubleWord = 3;
}

class _FpFmt {
  static const single = 0;
  static const double_ = 1;
}

class _AmoMemoryFaultException implements Exception {
  const _AmoMemoryFaultException();
}
