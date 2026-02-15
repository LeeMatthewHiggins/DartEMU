import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/util/bit_utils.dart';

class ExceptionHandler {
  ExceptionHandler({required this.state});

  final RiscVCpuState state;

  void raiseException(int cause, int tval) {
    final interruptBit = state.signBit;
    final isInterrupt = (cause & interruptBit) != 0;
    final exceptionCode = cause & ~interruptBit;

    final deleg = isInterrupt ? state.mideleg : state.medeleg;
    final delegToSupervisor =
        state.privilege.value <= PrivilegeLevel.supervisor.value &&
            ((deleg >> exceptionCode) & 1) != 0;

    if (delegToSupervisor) {
      _trapToSupervisor(cause, tval);
    } else {
      _trapToMachine(cause, tval);
    }
  }

  void handleMret() {
    final mpp =
        (state.mstatus >> _Mstatus.mppShift) &
        _Mstatus.privMask;
    final mpie =
        (state.mstatus >> _Mstatus.mpieShift) & 1;

    state.mstatus = (state.mstatus & ~(1 << mpp)) |
        (mpie << mpp);
    state.mstatus |= 1 << _Mstatus.mpieShift;
    state.mstatus &= ~(_Mstatus.privMask <<
        _Mstatus.mppShift);

    state.privilege = PrivilegeLevel.fromValue(mpp);
    state.pc = state.mepc;
    state.flushTlb();
  }

  void handleSret() {
    final spp =
        (state.mstatus >> _Mstatus.sppShift) & 1;
    final spie =
        (state.mstatus >> _Mstatus.spieShift) & 1;

    state.mstatus = (state.mstatus & ~(1 << spp)) |
        (spie << spp);
    state.mstatus |= 1 << _Mstatus.spieShift;
    state.mstatus &= ~(1 << _Mstatus.sppShift);

    state.privilege = PrivilegeLevel.fromValue(spp);
    state.pc = state.sepc;
    state.flushTlb();
  }

  bool hasPendingInterrupt() {
    final mask = state.mip & state.mie;
    if (mask == 0) return false;

    final priv = state.privilege.value;
    final mie =
        (state.mstatus >> _Mstatus.mieShift) & 1;
    final sie =
        (state.mstatus >> _Mstatus.sieShift) & 1;

    final enabledAtM =
        priv < PrivilegeLevel.machine.value ||
            (priv == PrivilegeLevel.machine.value &&
                mie != 0);
    final enabledAtS =
        priv < PrivilegeLevel.supervisor.value ||
            (priv == PrivilegeLevel.supervisor.value &&
                sie != 0);

    final mEnabled =
        enabledAtM ? mask & ~state.mideleg : 0;
    final sEnabled =
        enabledAtS ? mask & state.mideleg : 0;

    return (mEnabled | sEnabled) != 0;
  }

  void handlePendingInterrupt() {
    final mask = state.mip & state.mie;
    if (mask == 0) return;
    final irq = BitUtils.ctz32(mask);
    raiseException(irq | state.signBit, 0);
  }

  void _trapToMachine(int cause, int tval) {
    state.mepc = state.pc;
    state.mcause = cause;
    state.mtval = tval;

    final prevIe =
        (state.mstatus >> state.privilege.value) & 1;
    state.mstatus = (state.mstatus &
            ~(_Mstatus.privMask << _Mstatus.mppShift)) |
        (state.privilege.value << _Mstatus.mppShift);
    state.mstatus = (state.mstatus &
            ~(1 << _Mstatus.mpieShift)) |
        (prevIe << _Mstatus.mpieShift);
    state.mstatus &= ~(1 << _Mstatus.mieShift);

    state.privilege = PrivilegeLevel.machine;
    state.pc = state.mtvec;
    state.flushTlb();
  }

  void _trapToSupervisor(int cause, int tval) {
    state.sepc = state.pc;
    state.scause = cause;
    state.stval = tval;

    final prevIe =
        (state.mstatus >> state.privilege.value) & 1;
    state.mstatus =
        (state.mstatus & ~(1 << _Mstatus.sppShift)) |
            (state.privilege.value <<
                _Mstatus.sppShift);
    state.mstatus = (state.mstatus &
            ~(1 << _Mstatus.spieShift)) |
        (prevIe << _Mstatus.spieShift);
    state.mstatus &= ~(1 << _Mstatus.sieShift);

    state.privilege = PrivilegeLevel.supervisor;
    state.pc = state.stvec;
    state.flushTlb();
  }
}

class _Mstatus {
  static const sieShift = 1;
  static const mieShift = 3;
  static const spieShift = 5;
  static const mpieShift = 7;
  static const sppShift = 8;
  static const mppShift = 11;
  static const privMask = 3;
}
