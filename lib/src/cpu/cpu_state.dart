import 'dart:typed_data';

import 'package:dart_emu/src/cpu/fp_register_file.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';
import 'package:dart_emu/src/cpu/tlb.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

enum PrivilegeLevel {
  user(0),
  supervisor(1),
  hypervisor(2),
  machine(3);

  const PrivilegeLevel(this.value);
  final int value;

  static PrivilegeLevel fromValue(int v) => PrivilegeLevel.values[v];
}

abstract class RiscVCpuState {
  factory RiscVCpuState({
    required PhysMemoryMap memMap,
    Xlen xlen = Xlen.rv64,
  }) => switch (xlen) {
    Xlen.rv32 => _CpuState32(memMap: memMap),
    Xlen.rv64 => _CpuState64(memMap: memMap),
  };

  RiscVCpuState._({required this.memMap}) {
    regs[0] = 0;
  }

  final PhysMemoryMap memMap;

  Xlen get xlen;
  bool get isRv32;
  int get signBit;
  int get regMask;

  List<int> get regs;
  FpRegisterFile get fpRegs;

  int pc = 0;

  int fflags = 0;
  int frm = 0;

  late int curXlen = xlen.value;
  PrivilegeLevel privilege = PrivilegeLevel.machine;
  int fs = 0;
  int mxl = 0;

  int nCycles = 0;
  int instructionCounter = 0;
  bool powerDown = false;
  bool shutDown = false;
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

  /// Machine environment configuration (priv 1.12), and its RV32 high half.
  int menvcfg = 0;
  int menvcfgh = 0;

  /// Per-counter inhibit bits.
  int mcountinhibit = 0;

  /// Physical memory protection configuration and address registers.
  ///
  /// Stored so that M-mode firmware such as OpenSBI can program them and read
  /// back what it wrote. **The emulator does not enforce PMP**: the guest is
  /// already contained by the emulator boundary, and the registers exist so
  /// that standard firmware boots rather than to provide in-guest isolation.
  final List<int> pmpCfg = List.filled(pmpCfgCount, 0);
  final List<int> pmpAddr = List.filled(pmpEntryCount, 0);

  /// Debug trigger module select register. No triggers are implemented, so
  /// `tdata*` read as zero; the register exists because firmware probes it.
  int tselect = 0;

  /// Number of PMP address registers exposed.
  static const pmpEntryCount = 16;

  /// Number of PMP configuration registers exposed (packed, 8 entries each).
  static const pmpCfgCount = 4;

  int loadReservation = -1;

  int Function() rtcTimeRead = () => 0;
  void Function()? onTlbFlush;

  /// Services an environment call taken from supervisor mode, returning
  /// `true` when it was handled.
  ///
  /// Set when the machine provides the Supervisor Binary Interface itself
  /// instead of running separate M-mode firmware. Left null when firmware
  /// such as BBL is loaded, so its own SBI implementation handles the call
  /// through the normal trap path.
  bool Function(RiscVCpuState state)? onSupervisorEcall;

  final List<TlbEntry> tlbRead = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
    growable: false,
  );
  final List<TlbEntry> tlbWrite = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
    growable: false,
  );
  final List<TlbEntry> tlbCode = List.generate(
    TlbConstants.size,
    (_) => TlbEntry(),
    growable: false,
  );

  void flushTlb() {
    for (var i = 0; i < TlbConstants.size; i++) {
      tlbRead[i].invalidate();
      tlbWrite[i].invalidate();
      tlbCode[i].invalidate();
    }
    onTlbFlush?.call();
  }

  void setMip(int mask) => mip |= mask;

  void resetMip(int mask) => mip &= ~mask;
}

class _CpuState32 extends RiscVCpuState {
  _CpuState32({required super.memMap}) : super._();

  @override
  Xlen get xlen => Xlen.rv32;

  @override
  bool get isRv32 => true;

  @override
  int get signBit => _signBit32;

  @override
  int get regMask => _regMask32;

  @override
  final List<int> regs = Uint32List(_regCount);

  @override
  final FpRegisterFile fpRegs = FpRegisterFile();

  static const _signBit32 = 0x80000000;
  static const _regMask32 = 0xFFFFFFFF;
}

class _CpuState64 extends RiscVCpuState {
  _CpuState64({required super.memMap}) : super._();

  @override
  Xlen get xlen => Xlen.rv64;

  @override
  bool get isRv32 => false;

  @override
  int get signBit => _signBit64;

  @override
  int get regMask => _regMask64;

  @override
  final List<int> regs = Int64List(_regCount);

  @override
  final FpRegisterFile fpRegs = FpRegisterFile();

  static const int _signBit64 = Int64Const.signBit;
  static const _regMask64 = -1;
}

const _regCount = 32;
