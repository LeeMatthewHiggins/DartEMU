@TestOn('vm')
@Tags(['machine'])
library;

import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';
import 'package:test/test.dart';

/// A minimal kernel image: `ecall` followed by an endless branch.
///
/// Enough to prove that a supervisor environment call is serviced by the
/// built-in SBI rather than escaping to the trap path.
Uint8List _ecallThenSpin() {
  final image = Uint8List(64);
  ByteData.sublistView(image)
    ..setUint32(0, 0x00000073, Endian.little) // ecall
    ..setUint32(4, 0x0000006F, Endian.little); // j .
  return image;
}

MachineConfig _config() => MachineConfig(
  memorySizeMb: 16,
  kernelData: _ecallThenSpin(),
  useBuiltinSbi: true,
);

void main() {
  group('built-in SBI survives snapshot and restore', () {
    test('a booted machine has SBI wiring installed', () {
      final machine = RiscVMachine.fromConfig(_config());
      expect(machine.sbi, isNotNull);
      expect(machine.cpu.state.onSupervisorEcall, isNotNull);
      expect(machine.clint.supervisorTimer, isTrue);
    });

    test('a restored machine keeps SBI, the ecall hook and the timer mode', () {
      final snapshot = RiscVMachine.fromConfig(_config()).snapshot();
      final restored = RiscVMachine.restore(_config(), snapshot);

      expect(restored.sbi, isNotNull, reason: 'SBI must be reinstalled');
      expect(
        restored.cpu.state.onSupervisorEcall,
        isNotNull,
        reason: 'without this an ecall traps into machine mode, which is empty',
      );
      expect(
        restored.clint.supervisorTimer,
        isTrue,
        reason:
            'timers must stay supervisor-level; there is no firmware to '
            'reflect a machine timer interrupt down to the kernel',
      );
    });

    test('a restored machine actually services a supervisor ecall', () {
      final snapshot = RiscVMachine.fromConfig(_config()).snapshot();
      final restored = RiscVMachine.restore(_config(), snapshot);
      // Ask for the SBI spec version from supervisor mode.
      final state = restored.cpu.state
        ..privilege = PrivilegeLevel.supervisor
        ..regs[_a7] = _baseEid
        ..regs[_a6] = _getSpecVersionFid;
      final pcBefore = state.pc;

      restored.cpu.execute(1);

      expect(
        state.pc,
        pcBefore + 4,
        reason: 'a serviced call steps over the ecall instead of trapping',
      );
      expect(state.regs[_a0], 0, reason: 'SBI_SUCCESS');
      expect(state.regs[_a1] >> 24, 2, reason: 'SBI major version');
    });

    test('a firmware-booted machine installs no SBI handler', () {
      final machine = RiscVMachine.fromConfig(
        MachineConfig(memorySizeMb: 16, kernelData: _ecallThenSpin()),
      );
      expect(machine.sbi, isNull);
      expect(
        machine.cpu.state.onSupervisorEcall,
        isNull,
        reason: 'firmware provides its own SBI through the trap path',
      );
      expect(machine.clint.supervisorTimer, isFalse);
    });
  });
}

const _a0 = 10;
const _a1 = 11;
const _a6 = 16;
const _a7 = 17;
const _baseEid = 0x10;
const _getSpecVersionFid = 0;
