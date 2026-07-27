@TestOn('vm')
library;

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/csr.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

/// CSRs that standalone M-mode firmware (OpenSBI and similar) touches during
/// early boot. Before these existed every access raised an illegal
/// instruction, which no firmware survives.
class _Csr {
  static const mvendorid = 0xF11;
  static const marchid = 0xF12;
  static const mimpid = 0xF13;
  static const mconfigptr = 0xF15;
  static const menvcfg = 0x30A;
  static const mcountinhibit = 0x320;
  static const mseccfg = 0x747;
  static const tselect = 0x7A0;
  static const tdata1 = 0x7A1;
  static const tinfo = 0x7A4;
  static const pmpcfg0 = 0x3A0;
  static const pmpcfg1 = 0x3A1;
  static const pmpcfg2 = 0x3A2;
  static const pmpaddr0 = 0x3B0;
  static const pmpaddr15 = 0x3BF;
  static const pmpaddr63 = 0x3EF;
  static const unassigned = 0x5C0;
}

CsrHandler _handler({Xlen xlen = Xlen.rv64}) => CsrHandler(
  state: RiscVCpuState(memMap: PhysMemoryMap(), xlen: xlen),
);

void main() {
  group('machine information registers', () {
    test('read as zero rather than trapping', () {
      final csr = _handler();
      expect(csr.read(_Csr.mvendorid), 0);
      expect(csr.read(_Csr.marchid), 0);
      expect(csr.read(_Csr.mimpid), 0);
      expect(csr.read(_Csr.mconfigptr), 0);
    });

    test('are read-only — writes are ignored, not faults', () {
      final csr = _handler()..write(_Csr.mvendorid, 0xdead);
      expect(csr.read(_Csr.mvendorid), 0);
    });
  });

  group('PMP registers', () {
    test('address registers round-trip', () {
      final csr = _handler()..write(_Csr.pmpaddr0, 0x2000);
      expect(csr.read(_Csr.pmpaddr0), 0x2000);
    });

    test('config registers round-trip', () {
      final csr = _handler()..write(_Csr.pmpcfg0, 0x1f);
      expect(csr.read(_Csr.pmpcfg0), 0x1f);
    });

    test('on RV64 odd-numbered config registers read as zero', () {
      final csr = _handler()..write(_Csr.pmpcfg1, 0xff);
      expect(csr.read(_Csr.pmpcfg1), 0);
    });

    test('RV64 pmpcfg2 is a distinct register from pmpcfg0', () {
      final csr = _handler()
        ..write(_Csr.pmpcfg0, 0x11)
        ..write(_Csr.pmpcfg2, 0x22);
      expect(csr.read(_Csr.pmpcfg0), 0x11);
      expect(csr.read(_Csr.pmpcfg2), 0x22);
    });

    test('entries beyond the implemented count read zero without faulting', () {
      final csr = _handler();
      expect(csr.read(_Csr.pmpaddr15), 0);
      expect(csr.read(_Csr.pmpaddr63), 0);
      expect(() => csr.write(_Csr.pmpaddr63, 1), returnsNormally);
      expect(csr.read(_Csr.pmpaddr63), 0);
    });

    test('the full architectural window never throws', () {
      final csr = _handler();
      for (var addr = 0x3A0; addr <= 0x3EF; addr++) {
        expect(() => csr.read(addr), returnsNormally, reason: 'read $addr');
      }
    });
  });

  group('configuration and trigger registers', () {
    test('menvcfg round-trips', () {
      final csr = _handler()..write(_Csr.menvcfg, 0x1);
      expect(csr.read(_Csr.menvcfg), 0x1);
    });

    test('mcountinhibit round-trips', () {
      final csr = _handler()..write(_Csr.mcountinhibit, 0x5);
      expect(csr.read(_Csr.mcountinhibit), 0x5);
    });

    test('mseccfg reads zero', () {
      expect(_handler().read(_Csr.mseccfg), 0);
    });

    test('tselect round-trips and tdata reads zero (no triggers)', () {
      final csr = _handler()..write(_Csr.tselect, 3);
      expect(csr.read(_Csr.tselect), 3);
      expect(csr.read(_Csr.tdata1), 0);
      expect(csr.read(_Csr.tinfo), 0);
    });
  });

  group('regression guard', () {
    test('a genuinely unassigned CSR still raises an access fault', () {
      expect(
        () => _handler().read(_Csr.unassigned),
        throwsA(isA<CsrAccessException>()),
        reason: 'widening the CSR map must not swallow real illegal accesses',
      );
    });

    test('RV32 exposes pmpcfg1 as its own register', () {
      final csr = _handler(xlen: Xlen.rv32)..write(_Csr.pmpcfg1, 0x33);
      expect(csr.read(_Csr.pmpcfg1), 0x33);
    });
  });
}
