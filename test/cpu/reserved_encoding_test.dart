@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_executor.dart';
import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/csr.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

const _ramBase = 0x80000000;
const _ramSize = 0x10000;
const int _trapVector = _ramBase + 0x100;
const _illegalInstruction = 2;
const _timeCsr = 0xC01;

/// `op32` with funct7 = 1 and funct3 = 1: where a `mulhw` would sit if
/// RV64 defined one. It does not.
const _reservedMulhw = 0x020010BB;

/// `mulw x1, x0, x0`.
const _mulw = 0x020000BB;

CpuExecutor _executorRunning(int instruction) {
  final memMap = PhysMemoryMap();
  final ram = memMap.registerRam(addr: _ramBase, size: _ramSize);
  ByteData.sublistView(ram.byteData).setUint32(0, instruction, Endian.little);
  final cpu = CpuExecutor(memMap: memMap);
  cpu.state
    ..pc = _ramBase
    ..mtvec = _trapVector;
  return cpu;
}

void main() {
  group('reserved M-extension word encodings', () {
    test('trap as an illegal instruction instead of escaping to the host', () {
      final cpu = _executorRunning(_reservedMulhw);

      expect(() => cpu.execute(1), returnsNormally);

      expect(cpu.state.mcause, _illegalInstruction);
      expect(cpu.state.mepc, _ramBase);
      expect(cpu.state.pc, _trapVector);
    });

    test('a real mulw still executes', () {
      final cpu = _executorRunning(_mulw)..execute(1);

      expect(cpu.state.mcause, 0);
      expect(cpu.state.pc, _ramBase + 4);
    });
  });

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
