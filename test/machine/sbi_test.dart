@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/device/character_device.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:dart_emu/src/machine/sbi.dart';
import 'package:test/test.dart';

class _Console implements CharacterDevice {
  final out = <int>[];
  @override
  void writeData(Uint8List data) => out.addAll(data);
  @override
  Uint8List readData(int maxLength) => Uint8List(0);
}

class _Reg {
  static const a0 = 10;
  static const a1 = 11;
  static const a6 = 16;
  static const a7 = 17;
}

class _Eid {
  static const base = 0x10;
  static const time = 0x54494D45;
  static const hsm = 0x48534D;
  static const srst = 0x53525354;
  static const dbcn = 0x4442434E;
  static const unknown = 0x999999;
  static const legacyPutchar = 0x01;
  static const legacyGetchar = 0x02;
}

/// Drives [Sbi] the way a supervisor-mode `ecall` would.
class _Harness {
  _Harness() {
    sbi = Sbi(
      console: console,
      setTimer: (ticks) => timerTicks = ticks,
      shutdown: () => didShutdown = true,
      setSupervisorTimerPending: ({required pending}) => timerPending = pending,
    );
  }

  final state = RiscVCpuState(memMap: PhysMemoryMap());
  final console = _Console();
  late final Sbi sbi;
  int? timerTicks;
  bool didShutdown = false;
  bool? timerPending;

  ({int error, int value}) call(int eid, int fid, [List<int> args = const []]) {
    state.regs[_Reg.a7] = eid;
    state.regs[_Reg.a6] = fid;
    for (var i = 0; i < args.length; i++) {
      state.regs[_Reg.a0 + i] = args[i];
    }
    expect(sbi.handleEcall(state), isTrue, reason: 'call should be serviced');
    return (error: state.regs[_Reg.a0], value: state.regs[_Reg.a1]);
  }
}

void main() {
  group('base extension', () {
    test('reports SBI v2.0', () {
      final r = _Harness().call(_Eid.base, 0);
      expect(r.error, 0);
      expect(r.value >> 24, 2, reason: 'major version');
    });

    test('identifies this emulator, not OpenSBI or BBL', () {
      final implId = _Harness().call(_Eid.base, 1).value;
      expect(implId, isNot(0), reason: 'BBL');
      expect(implId, isNot(1), reason: 'OpenSBI');
    });

    test('probe reports supported extensions', () {
      final h = _Harness();
      for (final eid in [_Eid.time, _Eid.hsm, _Eid.srst, _Eid.dbcn]) {
        expect(h.call(_Eid.base, 3, [eid]).value, 1, reason: 'eid $eid');
      }
    });

    test('probe reports unsupported extensions as absent', () {
      expect(_Harness().call(_Eid.base, 3, [_Eid.unknown]).value, 0);
    });
  });

  group('timer', () {
    test('programs the compare value and clears the pending interrupt', () {
      final h = _Harness()..call(_Eid.time, 0, [12345]);
      expect(h.timerTicks, 12345);
      expect(
        h.timerPending,
        isFalse,
        reason: 'a newly programmed timer must not read as already expired',
      );
    });
  });

  group('console', () {
    test('legacy putchar writes a byte', () {
      final h = _Harness();
      for (final c in 'hi'.codeUnits) {
        h.call(_Eid.legacyPutchar, 0, [c]);
      }
      expect(String.fromCharCodes(h.console.out), 'hi');
    });

    test('legacy getchar returns -1 when no input is queued', () {
      final h = _Harness();
      h.state.regs[_Reg.a7] = _Eid.legacyGetchar;
      h.sbi.handleEcall(h.state);
      expect(h.state.regs[_Reg.a0], -1);
    });

    test('legacy getchar returns queued input', () {
      final h = _Harness();
      h.sbi.receiveChar(0x41);
      h.state.regs[_Reg.a7] = _Eid.legacyGetchar;
      h.sbi.handleEcall(h.state);
      expect(h.state.regs[_Reg.a0], 0x41);
    });

    test('debug console writes a buffer from guest memory', () {
      final h = _Harness();
      const addr = 0x80000100;
      h.state.memMap.registerRam(addr: 0x80000000, size: 0x1000);
      for (var i = 0; i < 3; i++) {
        h.state.memMap.physWriteU8(addr + i, 'abc'.codeUnitAt(i));
      }
      final r = h.call(_Eid.dbcn, 0, [3, addr]);
      expect(r.error, 0);
      expect(r.value, 3, reason: 'bytes written');
      expect(String.fromCharCodes(h.console.out), 'abc');
    });
  });

  group('hart state and reset', () {
    test('the calling hart reports as started', () {
      final r = _Harness().call(_Eid.hsm, 2);
      expect(r.error, 0);
      expect(r.value, 0, reason: 'STARTED');
    });

    test('system reset shuts the machine down', () {
      final h = _Harness()..call(_Eid.srst, 0);
      expect(h.didShutdown, isTrue);
    });
  });

  test('an unknown extension is refused rather than silently succeeding', () {
    expect(_Harness().call(_Eid.unknown, 0).error, -2);
  });
}
