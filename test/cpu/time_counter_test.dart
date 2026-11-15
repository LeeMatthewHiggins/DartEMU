@TestOn('vm')
library;

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/csr.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

const _timeCsr = 0xC01;

void main() {
  group('time counter', () {
    const beyond32Bits = (1 << 33) + 5;

    CsrHandler handler(Xlen xlen) => CsrHandler(
      state: RiscVCpuState(memMap: PhysMemoryMap(), xlen: xlen)
        ..rtcTimeRead = () => beyond32Bits,
    );

    test('is the full 64-bit value on RV64', () {
      expect(handler(Xlen.rv64).read(_timeCsr), beyond32Bits);
    });

    test('is the low half on RV32, where timeh carries the rest', () {
      expect(handler(Xlen.rv32).read(_timeCsr), 5);
    });
  });
}
