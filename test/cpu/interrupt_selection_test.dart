@TestOn('vm')
library;

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/exception.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

class _Irq {
  static const supervisorTimer = 5;
  static const machineTimer = 7;
}

class _Mstatus {
  static const int sie = 1 << 1;
  static const int mie = 1 << 3;
}

const int _supervisorTimerBit = 1 << _Irq.supervisorTimer;
const int _machineTimerBit = 1 << _Irq.machineTimer;

/// What firmware such as BBL or OpenSBI sets: supervisor interrupts are
/// delegated, machine ones are not.
const _firmwareDelegation = 0x222;

const _stvec = 0x8000;
const _mtvec = 0x4000;

RiscVCpuState _state({required PrivilegeLevel privilege, int mstatus = 0}) =>
    RiscVCpuState(memMap: PhysMemoryMap())
      ..privilege = privilege
      ..mstatus = mstatus
      ..mideleg = _firmwareDelegation
      ..mie = _supervisorTimerBit | _machineTimerBit
      ..stvec = _stvec
      ..mtvec = _mtvec;

int _cause(int value) => value & 0xFF;

void main() {
  group('interrupt selection under firmware delegation', () {
    test('a masked supervisor interrupt is not taken in place of a '
        'deliverable machine one', () {
      // Supervisor mode with SIE clear: the kernel is in a critical
      // section. The machine timer must still reach firmware, and the
      // supervisor timer must stay pending.
      final state = _state(privilege: PrivilegeLevel.supervisor)
        ..mip = _supervisorTimerBit | _machineTimerBit;
      final handler = ExceptionHandler(state: state);

      expect(handler.hasPendingInterrupt(), isTrue);
      handler.handlePendingInterrupt();

      expect(state.privilege, PrivilegeLevel.machine);
      expect(state.pc, _mtvec);
      expect(_cause(state.mcause), _Irq.machineTimer);
      expect(state.scause, 0, reason: 'supervisor trap must not be entered');
    });

    test('a supervisor interrupt is taken once SIE allows it', () {
      final state = _state(
        privilege: PrivilegeLevel.supervisor,
        mstatus: _Mstatus.sie,
      )..mip = _supervisorTimerBit;
      ExceptionHandler(state: state).handlePendingInterrupt();

      expect(state.privilege, PrivilegeLevel.supervisor);
      expect(state.pc, _stvec);
      expect(_cause(state.scause), _Irq.supervisorTimer);
    });

    test('nothing is taken in machine mode with MIE clear', () {
      final state = _state(privilege: PrivilegeLevel.machine)
        ..mip = _supervisorTimerBit | _machineTimerBit
        ..pc = 0x1234;
      final handler = ExceptionHandler(state: state);

      expect(handler.hasPendingInterrupt(), isFalse);
      handler.handlePendingInterrupt();

      expect(state.pc, 0x1234);
    });

    test('a machine interrupt is taken in machine mode with MIE set', () {
      final state = _state(
        privilege: PrivilegeLevel.machine,
        mstatus: _Mstatus.mie,
      )..mip = _supervisorTimerBit | _machineTimerBit;
      ExceptionHandler(state: state).handlePendingInterrupt();

      expect(_cause(state.mcause), _Irq.machineTimer);
    });
  });
}
