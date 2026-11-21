import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_executor.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

/// Shows the RV64 dispatch loop full-width values before the Dart JIT
/// optimizes it.
///
/// The JIT specializes each arithmetic site to the operand types it has
/// seen. Early in a boot most register values are small, so the loop is
/// compiled for small integers, and each site then deoptimizes the first
/// time a 64-bit value reaches it. Every site does so only once, but the
/// loop holds over a hundred of them and the VM stops optimizing a
/// function after its sixteenth deoptimization, which leaves the whole
/// interpreter running unoptimized — some fifteen times slower — for the
/// rest of the process.
///
/// Running one of every micro-op over small and full-width operands while
/// the loop is still unoptimized records both in its type feedback, so
/// the first optimized version already handles them. Ahead-of-time and
/// WebAssembly builds do not speculate and gain nothing from this; it
/// costs them well under a millisecond, once.
class HotLoopWarmup {
  static bool _done = false;

  /// Warms the loop the first time it is called; later calls do nothing.
  static void ensure() {
    if (_done) return;
    _done = true;

    final memMap = PhysMemoryMap();
    final ram = memMap.registerRam(addr: _ramBase, size: _ramSize);
    final program = buildProgram();
    final bytes = ByteData.sublistView(ram.byteData);
    for (var i = 0; i < program.length; i++) {
      bytes.setUint32(i * _insnBytes, program[i], Endian.little);
    }

    final cpu = CpuExecutor(memMap: memMap);
    for (final operands in _operandSets) {
      for (final dataAddress in _dataAddresses) {
        for (var i = 0; i < program.length; i++) {
          cpu.state
            ..pc = _ramBase + i * _insnBytes
            ..regs[_Reg.a] = operands.$1
            ..regs[_Reg.b] = operands.$2
            ..regs[_Reg.data] = dataAddress
            ..regs[_Reg.code] = _ramBase;
          cpu.execute(1);
        }
      }
    }
  }

  /// One instruction for every micro-op the dispatch loop handles itself.
  static List<int> buildProgram() {
    final program = <int>[
      _u(_Opcode.lui, _wideUpperImm),
      _u(_Opcode.auipc, _wideUpperImm),
      _i(_Opcode.opImm, _F3.addSub, _Reg.zero, 0, rd: _Reg.zero),
    ];

    for (final f3 in [
      _F3.addSub,
      _F3.slt,
      _F3.sltu,
      _F3.xor,
      _F3.or,
      _F3.and,
    ]) {
      program.add(_i(_Opcode.opImm, f3, _Reg.a, _smallImm));
    }
    program
      ..add(_i(_Opcode.opImm, _F3.sll, _Reg.a, _shiftAmount))
      ..add(_i(_Opcode.opImm, _F3.srl, _Reg.a, _shiftAmount))
      ..add(_i(_Opcode.opImm, _F3.srl, _Reg.a, _shiftAmount | _arithmeticImm))
      ..add(_i(_Opcode.opImm32, _F3.addSub, _Reg.a, _smallImm))
      ..add(_i(_Opcode.opImm32, _F3.sll, _Reg.a, _shiftAmount))
      ..add(_i(_Opcode.opImm32, _F3.srl, _Reg.a, _shiftAmount))
      ..add(
        _i(_Opcode.opImm32, _F3.srl, _Reg.a, _shiftAmount | _arithmeticImm),
      );

    for (var f3 = 0; f3 <= _F3.max; f3++) {
      program.add(_r(_Opcode.op, f3, _F7.base));
    }
    program
      ..add(_r(_Opcode.op, _F3.addSub, _F7.alternate))
      ..add(_r(_Opcode.op, _F3.srl, _F7.alternate));
    for (final f3 in [_F3.addSub, _F3.sll, _F3.srl]) {
      program.add(_r(_Opcode.op32, f3, _F7.base));
    }
    program
      ..add(_r(_Opcode.op32, _F3.addSub, _F7.alternate))
      ..add(_r(_Opcode.op32, _F3.srl, _F7.alternate));

    for (var f3 = 0; f3 <= _F3.max; f3++) {
      program.add(_r(_Opcode.op, f3, _F7.mulDiv));
    }
    for (final f3 in [_F3.addSub, _F3.div, _F3.divu, _F3.rem, _F3.remu]) {
      program.add(_r(_Opcode.op32, f3, _F7.mulDiv));
    }

    program
      ..add(_jal(_Reg.result))
      ..add(_jal(_Reg.zero));
    final jalrIndex = program.length;
    program
      ..add(_i(_Opcode.jalr, 0, _Reg.code, (jalrIndex + 1) * _insnBytes))
      ..add(
        _i(
          _Opcode.jalr,
          0,
          _Reg.code,
          (jalrIndex + 2) * _insnBytes,
          rd: _Reg.zero,
        ),
      );

    for (final f3 in _branchFunct3) {
      program.add(_branch(f3));
    }
    for (final f3 in _storeFunct3) {
      program.add(_store(f3));
    }
    for (final f3 in _loadFunct3) {
      program.add(_i(_Opcode.load, f3, _Reg.data, 0));
    }
    return program;
  }

  static int _u(int opcode, int upperImm) =>
      (upperImm << _Shift.upperImm) | (_Reg.result << _Shift.rd) | opcode;

  static int _i(int opcode, int f3, int rs1, int imm, {int rd = _Reg.result}) =>
      (imm << _Shift.imm) |
      (rs1 << _Shift.rs1) |
      (f3 << _Shift.funct3) |
      (rd << _Shift.rd) |
      opcode;

  static int _r(int opcode, int f3, int f7) =>
      (f7 << _Shift.funct7) |
      (_Reg.b << _Shift.rs2) |
      (_Reg.a << _Shift.rs1) |
      (f3 << _Shift.funct3) |
      (_Reg.result << _Shift.rd) |
      opcode;

  static int _store(int f3) =>
      (_Reg.a << _Shift.rs2) |
      (_Reg.data << _Shift.rs1) |
      (f3 << _Shift.funct3) |
      _Opcode.store;

  /// A branch to the next instruction, so it lands in the same place
  /// whether or not it is taken.
  static int _branch(int f3) =>
      (_Reg.b << _Shift.rs2) |
      (_Reg.a << _Shift.rs1) |
      (f3 << _Shift.funct3) |
      _nextInsnBranchImm |
      _Opcode.branch;

  static int _jal(int rd) => _nextInsnJumpImm | (rd << _Shift.rd) | _Opcode.jal;

  static const _ramBase = 0x80000000;
  static const _ramSize = 0x2000;
  static const _insnBytes = 4;

  /// Data lives on the page after the program. The second address is far
  /// outside the small-integer range and faults, which is the point: the
  /// address arithmetic sees a full-width value too.
  static const List<int> _dataAddresses = [_ramBase + 0x1000, _wide];

  static const int _wide = Int64Const.maxSigned & ~_alignmentMask;
  static const int _wideNegative = Int64Const.minSigned;
  static const _alignmentMask = 0xF;
  static const _small = 7;

  static const List<(int, int)> _operandSets = [
    (_small, _small),
    (_wide, _small),
    (_small, _wide),
    (_wide, _wideNegative),
    (_wideNegative, _wide),
  ];

  static const _wideUpperImm = 0xFFFFF;
  static const _smallImm = 5;
  static const _shiftAmount = 3;
  static const _arithmeticImm = 0x400;

  /// Offset 4 in the B-type and J-type immediate layouts.
  static const int _nextInsnBranchImm = 0x2 << 8;
  static const int _nextInsnJumpImm = 0x2 << 21;

  static const _branchFunct3 = [0, 1, 4, 5, 6, 7];
  static const _storeFunct3 = [3, 2, 1, 0];
  static const _loadFunct3 = [0, 1, 2, 3, 4, 5, 6];
}

class _Reg {
  static const zero = 0;
  static const a = 5;
  static const b = 6;
  static const data = 7;
  static const code = 9;
  static const result = 10;
}

class _Opcode {
  static const lui = 0x37;
  static const auipc = 0x17;
  static const jal = 0x6F;
  static const jalr = 0x67;
  static const branch = 0x63;
  static const load = 0x03;
  static const store = 0x23;
  static const opImm = 0x13;
  static const opImm32 = 0x1B;
  static const op = 0x33;
  static const op32 = 0x3B;
}

class _F3 {
  static const addSub = 0;
  static const sll = 1;
  static const slt = 2;
  static const sltu = 3;
  static const xor = 4;
  static const div = 4;
  static const srl = 5;
  static const divu = 5;
  static const or = 6;
  static const rem = 6;
  static const and = 7;
  static const remu = 7;
  static const max = 7;
}

class _F7 {
  static const base = 0x00;
  static const mulDiv = 0x01;
  static const alternate = 0x20;
}

class _Shift {
  static const rd = 7;
  static const funct3 = 12;
  static const upperImm = 12;
  static const rs1 = 15;
  static const rs2 = 20;
  static const imm = 20;
  static const funct7 = 25;
}
