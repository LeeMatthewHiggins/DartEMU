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
      signExtend: _signExtend32,
      toUnsigned: _toUnsigned32,
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
      signExtend: _identity,
      toUnsigned: _toUnsigned64,
    );
    _writeRd(rd, result);
  }

  int _dispatch({
    required int funct5,
    required int addr,
    required int rs2Val,
    required MemoryReadCallback read,
    required MemoryWriteCallback write,
    required int Function(int) signExtend,
    required int Function(int) toUnsigned,
  }) {
    return switch (funct5) {
      _Funct5.lr => _executeLr(addr, read),
      _Funct5.sc => _executeSc(addr, rs2Val, write),
      _Funct5.amoSwap => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (_, val2) => val2,
      ),
      _Funct5.amoAdd => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => signExtend(old + val2),
      ),
      _Funct5.amoXor => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => signExtend(old ^ val2),
      ),
      _Funct5.amoAnd => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => signExtend(old & val2),
      ),
      _Funct5.amoOr => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => signExtend(old | val2),
      ),
      _Funct5.amoMin => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => old < val2 ? old : val2,
      ),
      _Funct5.amoMax => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => old > val2 ? old : val2,
      ),
      _Funct5.amoMinU => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => toUnsigned(old) < toUnsigned(val2) ? old : val2,
      ),
      _Funct5.amoMaxU => _executeAmo(
        addr,
        rs2Val,
        read,
        write,
        (old, val2) => toUnsigned(old) > toUnsigned(val2) ? old : val2,
      ),
      _ => throw const IllegalAtomicException(),
    };
  }

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

  int _executeAmo(
    int addr,
    int rs2Val,
    MemoryReadCallback read,
    MemoryWriteCallback write,
    int Function(int oldVal, int rs2Val) op,
  ) {
    final oldVal = read(addr);
    final newVal = op(oldVal, rs2Val);
    write(addr, newVal);
    return oldVal;
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

  static int _identity(int value) => value;

  static int _toUnsigned32(int value) => value & _Masks.word;

  static int _toUnsigned64(int value) => value ^ _Masks.doubleSignBit;

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
}

class _Width {
  static const word = 2;
  static const doubleWord = 3;
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
