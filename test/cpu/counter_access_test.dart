@TestOn('vm')
library;

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/csr.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

/// The `cycle`, `time` and `instret` counters are granted one privilege level
/// at a time: `mcounteren` lets supervisor mode read them, and `scounteren`
/// passes that grant on to user mode. A level cannot hand on access it was
/// never given, so a user-mode read needs both.
class _Csr {
  static const time = 0xC01;
  static const cycle = 0xC00;
  static const instret = 0xC02;

  /// RV32 splits each counter across a low and a high CSR.
  static const cycleh = 0xC80;
  static const timeh = 0xC81;
  static const instreth = 0xC82;
}

class _Bit {
  static const int cycle = 1 << 0;
  static const int time = 1 << 1;
  static const int instret = 1 << 2;
  static const int all = cycle | time | instret;
}

({CsrHandler csr, RiscVCpuState state}) _harness({
  required PrivilegeLevel privilege,
  int mcounteren = 0,
  int scounteren = 0,
  Xlen xlen = Xlen.rv64,
}) {
  final state = RiscVCpuState(memMap: PhysMemoryMap(), xlen: xlen)
    ..privilege = privilege
    ..mcounteren = mcounteren
    ..scounteren = scounteren;
  return (csr: CsrHandler(state: state), state: state);
}

void main() {
  group('RV32 counter high halves', () {
    ({CsrHandler csr, RiscVCpuState state}) rv32({
      required PrivilegeLevel privilege,
      int mcounteren = 0,
      int scounteren = 0,
    }) => _harness(
      privilege: privilege,
      mcounteren: mcounteren,
      scounteren: scounteren,
      xlen: Xlen.rv32,
    );

    test('user mode needs both registers, as the low halves do', () {
      // A high half is the same counter. Checking only scounteren here would
      // leave a bypass: the value machine mode withheld is still readable,
      // just 32 bits at a time.
      final h = rv32(privilege: PrivilegeLevel.user, scounteren: _Bit.all);
      expect(() => h.csr.read(_Csr.cycleh), throwsA(isA<CsrAccessException>()));
      expect(
        () => h.csr.read(_Csr.instreth),
        throwsA(isA<CsrAccessException>()),
      );
      expect(() => h.csr.read(_Csr.timeh), throwsA(isA<CsrAccessException>()));
    });

    test('user mode is refused when supervisor mode withholds them', () {
      final h = rv32(privilege: PrivilegeLevel.user, mcounteren: _Bit.all);
      expect(() => h.csr.read(_Csr.cycleh), throwsA(isA<CsrAccessException>()));
      expect(
        () => h.csr.read(_Csr.instreth),
        throwsA(isA<CsrAccessException>()),
      );
    });

    test('user mode reads them when both registers grant it', () {
      final h = rv32(
        privilege: PrivilegeLevel.user,
        mcounteren: _Bit.all,
        scounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.cycleh), returnsNormally);
      expect(() => h.csr.read(_Csr.instreth), returnsNormally);
      expect(() => h.csr.read(_Csr.timeh), returnsNormally);
    });

    test('supervisor mode needs only mcounteren', () {
      final h = rv32(
        privilege: PrivilegeLevel.supervisor,
        mcounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.cycleh), returnsNormally);
      expect(() => h.csr.read(_Csr.instreth), returnsNormally);
    });

    test('a high half is gated by its own counter bit, not another', () {
      final h = rv32(
        privilege: PrivilegeLevel.user,
        mcounteren: _Bit.cycle,
        scounteren: _Bit.cycle,
      );
      expect(() => h.csr.read(_Csr.cycleh), returnsNormally);
      expect(
        () => h.csr.read(_Csr.instreth),
        throwsA(isA<CsrAccessException>()),
      );
    });

    test('RV64 has no high halves to read', () {
      final h = _harness(
        privilege: PrivilegeLevel.machine,
        mcounteren: _Bit.all,
        scounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.cycleh), throwsA(isA<CsrAccessException>()));
    });
  });

  group('machine mode', () {
    test('reads counters regardless of the enable registers', () {
      final h = _harness(privilege: PrivilegeLevel.machine);
      expect(() => h.csr.read(_Csr.time), returnsNormally);
      expect(() => h.csr.read(_Csr.cycle), returnsNormally);
      expect(() => h.csr.read(_Csr.instret), returnsNormally);
    });
  });

  group('supervisor mode', () {
    test('is refused when mcounteren withholds the counter', () {
      final h = _harness(privilege: PrivilegeLevel.supervisor);
      expect(() => h.csr.read(_Csr.time), throwsA(isA<CsrAccessException>()));
    });

    test('is allowed when mcounteren grants it', () {
      final h = _harness(
        privilege: PrivilegeLevel.supervisor,
        mcounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.time), returnsNormally);
    });

    test('scounteren alone does not grant supervisor access', () {
      final h = _harness(
        privilege: PrivilegeLevel.supervisor,
        scounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.time), throwsA(isA<CsrAccessException>()));
    });
  });

  group('user mode', () {
    test('needs both enable registers, not just scounteren', () {
      // Linux never writes scounteren itself, so firmware must set it. A
      // user-mode read that only consulted scounteren would let a guest read
      // counters that machine mode had withheld.
      final h = _harness(privilege: PrivilegeLevel.user, scounteren: _Bit.all);
      expect(() => h.csr.read(_Csr.time), throwsA(isA<CsrAccessException>()));
    });

    test('is refused when supervisor mode withholds the counter', () {
      final h = _harness(privilege: PrivilegeLevel.user, mcounteren: _Bit.all);
      expect(() => h.csr.read(_Csr.time), throwsA(isA<CsrAccessException>()));
    });

    test('is allowed when both registers grant it', () {
      final h = _harness(
        privilege: PrivilegeLevel.user,
        mcounteren: _Bit.all,
        scounteren: _Bit.all,
      );
      expect(() => h.csr.read(_Csr.time), returnsNormally);
    });

    test('each counter is gated by its own bit', () {
      final h = _harness(
        privilege: PrivilegeLevel.user,
        mcounteren: _Bit.time,
        scounteren: _Bit.time,
      );
      expect(() => h.csr.read(_Csr.time), returnsNormally);
      expect(() => h.csr.read(_Csr.cycle), throwsA(isA<CsrAccessException>()));
      expect(
        () => h.csr.read(_Csr.instret),
        throwsA(isA<CsrAccessException>()),
      );
    });
  });
}
