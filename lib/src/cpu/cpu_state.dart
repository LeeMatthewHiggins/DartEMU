import 'dart:typed_data';

import 'package:dart_emu/src/cpu/tlb.dart';
import 'package:dart_emu/src/ram/phys_memory_map.dart';

enum PrivilegeLevel {
  user(0),
  supervisor(1),
  hypervisor(2),
  machine(3);

  const PrivilegeLevel(this.value);
  final int value;

  static PrivilegeLevel fromValue(int v) =>
      PrivilegeLevel.values.firstWhere((e) => e.value == v);
}

class RiscVCpuState {
  RiscVCpuState({required this.memMap}) {
    regs[0] = 0;
  }

  final PhysMemoryMap memMap;

  int pc = 0;
  final Int64List regs = Int64List(_regCount);
  final Int64List fpRegs = Int64List(_regCount);

  int fflags = 0;
  int frm = 0;

  int curXlen = _defaultXlen;
  PrivilegeLevel privilege = PrivilegeLevel.machine;
  int fs = 0;
  int mxl = 0;

  int nCycles = 0;
  int instructionCounter = 0;
  bool powerDown = false;
  int pendingException = -1;
  int pendingTval = 0;

  int mstatus = 0;
  int mtvec = 0;
  int mscratch = 0;
  int mepc = 0;
  int mcause = 0;
  int mtval = 0;
  int mhartid = 0;
  int misa = 0;
  int mie = 0;
  int mip = 0;
  int medeleg = 0;
  int mideleg = 0;
  int mcounteren = 0;

  int stvec = 0;
  int sscratch = 0;
  int sepc = 0;
  int scause = 0;
  int stval = 0;
  int satp = 0;
  int scounteren = 0;

  int loadReservation = -1;

  final List<TlbEntry> tlbRead = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
  );
  final List<TlbEntry> tlbWrite = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
  );
  final List<TlbEntry> tlbCode = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
  );

  void flushTlb() {
    for (var i = 0; i < TlbConstants.size; i++) {
      tlbRead[i].invalidate();
      tlbWrite[i].invalidate();
      tlbCode[i].invalidate();
    }
  }

  void setMip(int mask) => mip |= mask;

  void resetMip(int mask) => mip &= ~mask;

  static const _regCount = 32;
  static const _defaultXlen = 64;
}
