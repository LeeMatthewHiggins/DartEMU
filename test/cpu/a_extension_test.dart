@TestOn('vm')
library;

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/extensions/a_extension.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:test/test.dart';

class _Funct5 {
  static const amoAdd = 0x00;
  static const amoSwap = 0x01;
  static const amoMin = 0x10;
  static const amoMax = 0x14;
  static const amoMinU = 0x18;
  static const amoMaxU = 0x1C;
  static const reserved = 0x05;
}

const _wordWidth = 2;
const _doubleWidth = 3;
const _funct5Shift = 2;
const _rd = 5;
const _addr = 0x1000;
const _minusOne32 = 0xFFFFFFFF;

/// One memory cell standing in for guest RAM. Word reads sign-extend, as
/// the executor's do.
class _Cell {
  _Cell(this.value);

  int value;
  int writes = 0;

  int readWord(int addr) => value.toSigned(32);

  int readDouble(int addr) => value;

  void write(int addr, int newValue) {
    value = newValue;
    writes++;
  }
}

RiscVCpuState _state() => RiscVCpuState(memMap: PhysMemoryMap());

void _run(
  AExtension ext,
  _Cell cell, {
  required int funct5,
  required int rs2,
  int width = _wordWidth,
}) => ext.executeAtomic(
  funct3: width,
  funct7: funct5 << _funct5Shift,
  rd: _rd,
  rs1Val: _addr,
  rs2Val: rs2,
  readWord: cell.readWord,
  readDouble: cell.readDouble,
  writeWord: cell.write,
  writeDouble: cell.write,
);

int _low32(int value) => value & _minusOne32;

void main() {
  group('word AMOs compare 32-bit values', () {
    test('amomin.w treats 0xFFFFFFFF as -1, not as a large number', () {
      final state = _state();
      final cell = _Cell(5);
      _run(AExtension(state: state), cell, funct5: _Funct5.amoMin, rs2: -1);

      expect(_low32(cell.value), _minusOne32);
      expect(state.regs[_rd], 5, reason: 'rd receives the old value');
    });

    test('amomax.w keeps the positive value over a negative one', () {
      final cell = _Cell(5);
      _run(AExtension(state: _state()), cell, funct5: _Funct5.amoMax, rs2: -1);

      expect(_low32(cell.value), 5);
    });

    test('amominu.w and amomaxu.w treat 0xFFFFFFFF as the largest', () {
      final low = _Cell(5);
      _run(AExtension(state: _state()), low, funct5: _Funct5.amoMinU, rs2: -1);
      expect(_low32(low.value), 5);

      final high = _Cell(5);
      _run(AExtension(state: _state()), high, funct5: _Funct5.amoMaxU, rs2: -1);
      expect(_low32(high.value), _minusOne32);
    });

    test('amoadd.w wraps at 32 bits and sign-extends the old value', () {
      final state = _state();
      final cell = _Cell(_minusOne32);
      _run(AExtension(state: state), cell, funct5: _Funct5.amoAdd, rs2: 2);

      expect(_low32(cell.value), 1);
      expect(state.regs[_rd], -1);
    });
  });

  group('doubleword AMOs', () {
    test('amominu.d compares across the sign boundary as unsigned', () {
      final cell = _Cell(1);
      _run(
        AExtension(state: _state()),
        cell,
        funct5: _Funct5.amoMinU,
        rs2: -1,
        width: _doubleWidth,
      );

      expect(cell.value, 1);
    });

    test('amoswap.d stores the operand and returns the old value', () {
      final state = _state();
      final cell = _Cell(7);
      _run(
        AExtension(state: state),
        cell,
        funct5: _Funct5.amoSwap,
        rs2: 9,
        width: _doubleWidth,
      );

      expect(cell.value, 9);
      expect(state.regs[_rd], 7);
    });
  });

  test('a reserved encoding is rejected before memory is touched', () {
    final cell = _Cell(5);
    expect(
      () => _run(
        AExtension(state: _state()),
        cell,
        funct5: _Funct5.reserved,
        rs2: 1,
      ),
      throwsA(isA<IllegalAtomicException>()),
    );
    expect(cell.writes, 0);
    expect(cell.value, 5);
  });
}
