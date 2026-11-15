import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/platform/int64_const.dart';

typedef MemoryReadCallback = int Function(int addr);
typedef MemoryWriteCallback = void Function(int addr, int value);

class AExtension {
  factory AExtension({required RiscVCpuState state}) =>
      state.isRv32 ? _AExtension32(state: state) : _AExtension64(state: state);

  AExtension._({required this.state});

  final RiscVCpuState state;

  void executeAtomic({
    required int funct3,
    required int funct7,
    required int rd,
    required int rs1Val,
    required int rs2Val,
    required MemoryReadCallback readWord,
    required MemoryReadCallback readDouble,
    required MemoryWriteCallback writeWord,
    required MemoryWriteCallback writeDouble,
  }) {
    final funct5 = funct7 >> _Shifts.funct5;
    switch (funct3) {
      case _Width.word:
        _executeWord(
          funct5: funct5,
          rd: rd,
          addr: rs1Val,
          rs2Val: rs2Val,
          read: readWord,
          write: writeWord,
        );
      case _Width.doubleWord:
        _executeDouble(
          funct5: funct5,
          rd: rd,
          addr: rs1Val,
          rs2Val: rs2Val,
          read: readDouble,
          write: writeDouble,
        );
      default:
        throw const IllegalAtomicException();
    }
  }

  void _executeWord({
    required int funct5,
    required int rd,
    required int addr,
    required int rs2Val,
    required MemoryReadCallback read,
    required MemoryWriteCallback write,
  }) {
    final result = _dispatch(
      funct5: funct5,
      addr: addr,
      rs2Val: _truncate32(rs2Val),
      read: read,
      write: write,
      isWord: true,
    );
    _writeRd(rd, _signExtend32(result));
  }

  void _executeDouble({
    required int funct5,
    required int rd,
    required int addr,
    required int rs2Val,
    required MemoryReadCallback read,
    required MemoryWriteCallback write,
  }) {
    final result = _dispatch(
      funct5: funct5,
      addr: addr,
      rs2Val: rs2Val,
      read: read,
      write: write,
      isWord: false,
    );
    _writeRd(rd, result);
  }

  int _dispatch({
    required int funct5,
    required int addr,
    required int rs2Val,
    required MemoryReadCallback read,
    required MemoryWriteCallback write,
    required bool isWord,
  }) {
    if (funct5 == _Funct5.lr) return _executeLr(addr, read);
    if (funct5 == _Funct5.sc) return _executeSc(addr, rs2Val, write);
    if (!_isAmo(funct5)) throw const IllegalAtomicException();

    final oldVal = read(addr);
    write(addr, _amoResult(funct5, oldVal, rs2Val, isWord));
    return oldVal;
  }

  static bool _isAmo(int funct5) =>
      funct5 <= _Funct5.amoSwap ||
      (funct5 & _Funct5.amoLowBitsMask) == 0 && funct5 <= _Funct5.amoMaxU;

  /// The value an AMO stores. Word operands are compared as 32-bit
  /// quantities whatever the width of the registers that carry them.
  static int _amoResult(int funct5, int oldVal, int rs2Val, bool isWord) {
    switch (funct5) {
      case _Funct5.amoSwap:
        return rs2Val;
      case _Funct5.amoAdd:
        return isWord ? _signExtend32(oldVal + rs2Val) : oldVal + rs2Val;
      case _Funct5.amoXor:
        return isWord ? _signExtend32(oldVal ^ rs2Val) : oldVal ^ rs2Val;
      case _Funct5.amoAnd:
        return isWord ? _signExtend32(oldVal & rs2Val) : oldVal & rs2Val;
      case _Funct5.amoOr:
        return isWord ? _signExtend32(oldVal | rs2Val) : oldVal | rs2Val;
      case _Funct5.amoMin:
        return _signedKey(oldVal, isWord) < _signedKey(rs2Val, isWord)
            ? oldVal
            : rs2Val;
      case _Funct5.amoMax:
        return _signedKey(oldVal, isWord) > _signedKey(rs2Val, isWord)
            ? oldVal
            : rs2Val;
      case _Funct5.amoMinU:
        return _unsignedKey(oldVal, isWord) < _unsignedKey(rs2Val, isWord)
            ? oldVal
            : rs2Val;
      default:
        return _unsignedKey(oldVal, isWord) > _unsignedKey(rs2Val, isWord)
            ? oldVal
            : rs2Val;
    }
  }

  static int _signedKey(int value, bool isWord) =>
      isWord ? value.toSigned(_Width.wordBits) : value;

  static int _unsignedKey(int value, bool isWord) =>
      isWord ? value & _Masks.word : value ^ _Masks.doubleSignBit;

  int _executeLr(int addr, MemoryReadCallback read) {
    state.loadReservation = addr;
    return read(addr);
  }

  int _executeSc(int addr, int value, MemoryWriteCallback write) {
    if (state.loadReservation == addr) {
      write(addr, value);
      state.loadReservation = _noReservation;
      return _scSuccess;
    }
    state.loadReservation = _noReservation;
    return _scFailure;
  }

  void _writeRd(int rd, int value) {
    if (rd != 0) {
      state.regs[rd] = value;
    }
  }

  static int _signExtend32(int value) {
    final masked = value & _Masks.word;
    if ((masked & _Masks.wordSignBit) != 0) {
      return masked | _Masks.wordSignExtension;
    }
    return masked;
  }

  static int _truncate32(int value) => value & _Masks.word;

  static const _noReservation = -1;
  static const _scSuccess = 0;
  static const _scFailure = 1;
}

class _AExtension64 extends AExtension {
  _AExtension64({required super.state}) : super._();
}

class _AExtension32 extends AExtension {
  _AExtension32({required super.state}) : super._();

  @override
  void executeAtomic({
    required int funct3,
    required int funct7,
    required int rd,
    required int rs1Val,
    required int rs2Val,
    required MemoryReadCallback readWord,
    required MemoryReadCallback readDouble,
    required MemoryWriteCallback writeWord,
    required MemoryWriteCallback writeDouble,
  }) {
    if (funct3 != _Width.word) throw const IllegalAtomicException();
    final funct5 = funct7 >> _Shifts.funct5;
    _executeWord(
      funct5: funct5,
      rd: rd,
      addr: rs1Val,
      rs2Val: rs2Val,
      read: readWord,
      write: writeWord,
    );
  }
}

class IllegalAtomicException implements Exception {
  const IllegalAtomicException();
}

class _Funct5 {
  static const amoAdd = 0x00;
  static const amoSwap = 0x01;
  static const lr = 0x02;
  static const sc = 0x03;
  static const amoXor = 0x04;
  static const amoOr = 0x08;
  static const amoAnd = 0x0C;
  static const amoMin = 0x10;
  static const amoMax = 0x14;
  static const amoMinU = 0x18;
  static const amoMaxU = 0x1C;

  /// Every AMO above `amoswap` has its two low bits clear.
  static const amoLowBitsMask = 0x03;
}

class _Width {
  static const word = 2;
  static const doubleWord = 3;
  static const wordBits = 32;
}

class _Shifts {
  static const funct5 = 2;
}

class _Masks {
  static const word = 0xFFFFFFFF;
  static const wordSignBit = 0x80000000;
  static const int wordSignExtension = ~word;
  static const int doubleSignBit = Int64Const.signBit;
}
