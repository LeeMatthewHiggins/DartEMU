import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';

class CsrHandler {
  CsrHandler({required this.state});

  final RiscVCpuState state;

  int read(int csrAddr) {
    _checkAccess(csrAddr);
    return switch (csrAddr) {
      _Addr.fflags => state.fflags,
      _Addr.frm => state.frm,
      _Addr.fcsr => state.fflags | (state.frm << _frmShift),
      _Addr.cycle || _Addr.instret => _readCounter(csrAddr),
      _Addr.time => _readTime(),
      _Addr.cycleh || _Addr.instreth => _readCounterHigh(csrAddr),
      _Addr.timeh => _readTimeHigh(),
      _Addr.mcycle || _Addr.minstret => state.instructionCounter,
      _Addr.mcycleh || _Addr.minstreth => _readMCounterHigh(),
      _Addr.sstatus => _getMstatus(_sstatusMask),
      _Addr.sie => state.mie & state.mideleg,
      _Addr.stvec => state.stvec,
      _Addr.scounteren => state.scounteren,
      _Addr.sscratch => state.sscratch,
      _Addr.sepc => state.sepc,
      _Addr.scause => state.scause,
      _Addr.stval => state.stval,
      _Addr.sip => state.mip & state.mideleg,
      _Addr.satp => state.satp,
      _Addr.mstatus => _getMstatus(_Mstatus.allBits),
      _Addr.misa => state.misa,
      _Addr.medeleg => state.medeleg,
      _Addr.mideleg => state.mideleg,
      _Addr.mie => state.mie,
      _Addr.mtvec => state.mtvec,
      _Addr.mcounteren => state.mcounteren,
      _Addr.mscratch => state.mscratch,
      _Addr.mepc => state.mepc,
      _Addr.mcause => state.mcause,
      _Addr.mtval => state.mtval,
      _Addr.mip => state.mip,
      _Addr.mhartid => state.mhartid,
      _ => throw CsrAccessException(csrAddr, state.privilege),
    };
  }

  void write(int csrAddr, int value) {
    _checkAccess(csrAddr);
    switch (csrAddr) {
      case _Addr.fflags:
        state.fflags = value & _fflagsMask;
      case _Addr.frm:
        state.frm = value & _frmMask;
      case _Addr.fcsr:
        state.fflags = value & _fflagsMask;
        state.frm = (value >> _frmShift) & _frmMask;
      case _Addr.sstatus:
        _setMstatus((state.mstatus & ~_sstatusMask) | (value & _sstatusMask));
      case _Addr.sie:
        state.mie = (state.mie & ~state.mideleg) | (value & state.mideleg);
      case _Addr.stvec:
        state.stvec = value;
      case _Addr.scounteren:
        state.scounteren = value;
      case _Addr.sscratch:
        state.sscratch = value;
      case _Addr.sepc:
        state.sepc = value;
      case _Addr.scause:
        state.scause = value;
      case _Addr.stval:
        state.stval = value;
      case _Addr.sip:
        state.mip = (state.mip & ~state.mideleg) | (value & state.mideleg);
      case _Addr.satp:
        state.satp = value;
        state.flushTlb();
      case _Addr.mstatus:
        _setMstatus(value);
      case _Addr.misa:
        state.misa = value;
      case _Addr.medeleg:
        state.medeleg = value;
      case _Addr.mideleg:
        state.mideleg = value;
      case _Addr.mie:
        state.mie = value;
      case _Addr.mtvec:
        state.mtvec = value;
      case _Addr.mcounteren:
        state.mcounteren = value;
      case _Addr.mscratch:
        state.mscratch = value;
      case _Addr.mepc:
        state.mepc = value;
      case _Addr.mcause:
        state.mcause = value;
      case _Addr.mtval:
        state.mtval = value;
      case _Addr.mip:
        state.mip = value;
    }
  }

  int _getMstatus(int mask) {
    var val = state.mstatus & mask;
    final fsDirty = (val & _Mstatus.fsMask) == _Mstatus.fsMask;
    final xsDirty = (val & _Mstatus.xsMask) == _Mstatus.xsMask;
    if (fsDirty || xsDirty) {
      val |= _sdBit;
    }
    return val;
  }

  void _setMstatus(int val) {
    final mod = state.mstatus ^ val;
    final mprvChanged = (mod & _Mstatus.tlbFlushBits) != 0;
    final mprvMppChanged =
        (state.mstatus & _Mstatus.mprvBit) != 0 &&
        (mod & _Mstatus.mppMask) != 0;
    if (mprvChanged || mprvMppChanged) {
      state.flushTlb();
    }

    var mask = _Mstatus.writeMask;
    if (!state.isRv32) {
      final uxl = (val >> _Mstatus.uxlShift) & _Mstatus.xlMask;
      if (uxl >= 1 && uxl <= _mxlRv64) {
        mask |= _Mstatus.uxlMask;
      }
      final sxl = (val >> _Mstatus.sxlShift) & _Mstatus.xlMask;
      if (sxl >= 1 && sxl <= _mxlRv64) {
        mask |= _Mstatus.sxlMask;
      }
    }

    state.mstatus = (state.mstatus & ~mask) | (val & mask);
  }

  void _checkCounterAccess(int csrAddr) {
    final counterBit = 1 << (csrAddr & _counterBitMask);
    if (state.privilege.value < PrivilegeLevel.machine.value) {
      final counteren = state.privilege.value < PrivilegeLevel.supervisor.value
          ? state.scounteren
          : state.mcounteren;
      if ((counteren & counterBit) == 0) {
        throw CsrAccessException(csrAddr, state.privilege);
      }
    }
  }

  int _readCounter(int csrAddr) {
    _checkCounterAccess(csrAddr);
    return state.instructionCounter;
  }

  int _readTime() {
    _checkCounterAccess(_Addr.time);
    final rtcTime = state.rtcTimeRead();
    return rtcTime & _counterHighMask;
  }

  int _readTimeHigh() {
    if (!state.isRv32) {
      throw CsrAccessException(_Addr.timeh, state.privilege);
    }
    _checkCounterAccess(_Addr.time);
    return (state.rtcTimeRead() >> _counterHighShift) & _counterHighMask;
  }

  int _readCounterHigh(int csrAddr) {
    if (!state.isRv32) {
      throw CsrAccessException(csrAddr, state.privilege);
    }
    final lowAddr = csrAddr - _counterHighOffset;
    final counterBit = 1 << (lowAddr & _counterBitMask);
    if (state.privilege.value < PrivilegeLevel.machine.value) {
      final counteren = state.privilege.value < PrivilegeLevel.supervisor.value
          ? state.scounteren
          : state.mcounteren;
      if ((counteren & counterBit) == 0) {
        throw CsrAccessException(csrAddr, state.privilege);
      }
    }
    return (state.instructionCounter >> _counterHighShift) & _counterHighMask;
  }

  int _readMCounterHigh() {
    if (!state.isRv32) {
      throw CsrAccessException(0, state.privilege);
    }
    return (state.instructionCounter >> _counterHighShift) & _counterHighMask;
  }

  void _checkAccess(int csrAddr) {
    final requiredPriv = (csrAddr >> _privShift) & _privMask;
    if (state.privilege.value < requiredPriv) {
      throw CsrAccessException(csrAddr, state.privilege);
    }
  }

  int get _sdBit => state.isRv32 ? _Mstatus.sdBit32 : _Mstatus.sdBit64;

  int get _sstatusMask =>
      state.isRv32 ? _Mstatus.sstatusMask32 : _Mstatus.sstatusMask64;

  static const _privShift = 8;
  static const _privMask = 3;
  static const _counterBitMask = 0x1F;
  static const _counterHighOffset = 0x80;
  static const _counterHighShift = 32;
  static const _counterHighMask = 0xFFFFFFFF;
  static const _fflagsMask = 0x1F;
  static const _frmMask = 0x07;
  static const _frmShift = 5;
  static const _mxlRv64 = 2;
}

class CsrAccessException implements Exception {
  CsrAccessException(this.csrAddr, this.privilege);

  final int csrAddr;
  final PrivilegeLevel privilege;

  @override
  String toString() =>
      'CSR access denied: 0x${csrAddr.toRadixString(16)} '
      'at privilege ${privilege.name}';
}

class _Addr {
  static const fflags = 0x001;
  static const frm = 0x002;
  static const fcsr = 0x003;
  static const cycle = 0xC00;
  static const time = 0xC01;
  static const instret = 0xC02;
  static const cycleh = 0xC80;
  static const timeh = 0xC81;
  static const instreth = 0xC82;
  static const sstatus = 0x100;
  static const sie = 0x104;
  static const stvec = 0x105;
  static const scounteren = 0x106;
  static const sscratch = 0x140;
  static const sepc = 0x141;
  static const scause = 0x142;
  static const stval = 0x143;
  static const sip = 0x144;
  static const satp = 0x180;
  static const mstatus = 0x300;
  static const misa = 0x301;
  static const medeleg = 0x302;
  static const mideleg = 0x303;
  static const mie = 0x304;
  static const mtvec = 0x305;
  static const mcounteren = 0x306;
  static const mscratch = 0x340;
  static const mepc = 0x341;
  static const mcause = 0x342;
  static const mtval = 0x343;
  static const mip = 0x344;
  static const mcycle = 0xB00;
  static const minstret = 0xB02;
  static const mcycleh = 0xB80;
  static const minstreth = 0xB82;
  static const mhartid = 0xF14;
}

class _Mstatus {
  static const int uieBit = 1 << 0;
  static const int sieBit = 1 << 1;
  static const int mieBit = 1 << 3;
  static const int upieBit = 1 << 4;
  static const int spieBit = 1 << 5;
  static const int mpieBit = 1 << 7;
  static const int sppBit = 1 << 8;
  static const int mppMask = 3 << 11;
  static const int fsMask = 3 << 13;
  static const int xsMask = 3 << 15;
  static const int mprvBit = 1 << 17;
  static const int sumBit = 1 << 18;
  static const int mxrBit = 1 << 19;

  static const uxlShift = 32;
  static const sxlShift = 34;
  static const xlMask = 3;
  static const int uxlMask = 3 << 32;
  static const int sxlMask = 3 << 34;

  static const int sdBit32 = 1 << 31;
  static const int sdBit64 = Int64Const.signBit;

  static const int _sstatusMaskBase =
      uieBit |
      sieBit |
      upieBit |
      spieBit |
      sppBit |
      fsMask |
      xsMask |
      sumBit |
      mxrBit;

  static const int sstatusMask32 = _sstatusMaskBase;
  static const int sstatusMask64 = _sstatusMaskBase | uxlMask;

  static const int writeMask =
      uieBit |
      sieBit |
      mieBit |
      upieBit |
      spieBit |
      mpieBit |
      sppBit |
      mppMask |
      fsMask |
      mprvBit |
      sumBit |
      mxrBit;

  static const int tlbFlushBits = mprvBit | sumBit | mxrBit;

  static const allBits = -1;
}
