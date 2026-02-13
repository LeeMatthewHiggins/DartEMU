import 'package:dart_emu/src/cpu/cpu_state.dart';

class CsrHandler {
  CsrHandler({required this.state});

  final RiscVCpuState state;

  int read(int csrAddr) {
    _checkAccess(csrAddr);
    return switch (csrAddr) {
      _Addr.fflags => state.fflags,
      _Addr.frm => state.frm,
      _Addr.fcsr => state.fflags | (state.frm << _frmShift),
      _Addr.cycle || _Addr.mcycle => state.instructionCounter,
      _Addr.instret || _Addr.minstret => state.instructionCounter,
      _Addr.sstatus => state.mstatus & _sstatusMask,
      _Addr.sie => state.mie & state.mideleg,
      _Addr.stvec => state.stvec,
      _Addr.scounteren => state.scounteren,
      _Addr.sscratch => state.sscratch,
      _Addr.sepc => state.sepc,
      _Addr.scause => state.scause,
      _Addr.stval => state.stval,
      _Addr.sip => state.mip & state.mideleg,
      _Addr.satp => state.satp,
      _Addr.mstatus => state.mstatus,
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
      _ => 0,
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
        state.mstatus = (state.mstatus & ~_sstatusMask) |
            (value & _sstatusMask);
      case _Addr.sie:
        state.mie = (state.mie & ~state.mideleg) |
            (value & state.mideleg);
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
        state.mip = (state.mip & ~state.mideleg) |
            (value & state.mideleg);
      case _Addr.satp:
        state.satp = value;
        state.flushTlb();
      case _Addr.mstatus:
        state.mstatus = value;
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

  void _checkAccess(int csrAddr) {
    final requiredPriv = (csrAddr >> _privShift) & _privMask;
    if (state.privilege.value < requiredPriv) {
      throw CsrAccessException(csrAddr, state.privilege);
    }
  }

  static const _privShift = 8;
  static const _privMask = 3;
  static const _fflagsMask = 0x1F;
  static const _frmMask = 0x07;
  static const _frmShift = 5;
  static const _sstatusMask = 0x800DE162;
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
  static const instret = 0xC02;
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
  static const mhartid = 0xF14;
}
