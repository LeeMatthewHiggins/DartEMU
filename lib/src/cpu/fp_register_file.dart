import 'dart:collection';
import 'dart:typed_data';

/// Fixed-size list of 32 floating-point registers, each 64 bits wide.
///
/// Backed by [ByteData] so that all 64 bits are preserved on every
/// platform, including web where `Int64List` is unavailable.
///
/// Implements [List<int>] for backward compatibility.  On native the
/// [operator[]] / [operator[]=] round-trip is exact.  On web,
/// values wider than 53 bits may lose precision through the `int`
/// interface; use the typed accessors ([readDouble], [writePair],
/// [readLo], [readHi]) for guaranteed fidelity.
class FpRegisterFile extends ListBase<int> {
  final ByteData _data = ByteData(_Layout.byteCount);

  @override
  int get length => _Layout.regCount;

  @override
  set length(int _) => throw UnsupportedError('Fixed-length register file');

  @override
  int operator [](int reg) {
    final offset = reg * _Layout.bytesPerReg;
    final lo = _data.getUint32(offset, Endian.little);
    final hi = _data.getUint32(offset + _Layout.hiOffset, Endian.little);
    return lo | (hi << _Bits.word);
  }

  @override
  void operator []=(int reg, int value) {
    final offset = reg * _Layout.bytesPerReg;
    _data
      ..setUint32(offset, value & _Mask.word, Endian.little)
      ..setUint32(
        offset + _Layout.hiOffset,
        (value >>> _Bits.word) & _Mask.word,
        Endian.little,
      );
  }

  double readDouble(int reg) =>
      _data.getFloat64(reg * _Layout.bytesPerReg, Endian.little);

  void writeDouble(int reg, double value) =>
      _data.setFloat64(reg * _Layout.bytesPerReg, value, Endian.little);

  int readLo(int reg) =>
      _data.getUint32(reg * _Layout.bytesPerReg, Endian.little);

  int readHi(int reg) =>
      _data.getUint32(
        reg * _Layout.bytesPerReg + _Layout.hiOffset,
        Endian.little,
      );

  void writePair(int reg, int lo, int hi) {
    final offset = reg * _Layout.bytesPerReg;
    _data
      ..setUint32(offset, lo, Endian.little)
      ..setUint32(offset + _Layout.hiOffset, hi, Endian.little);
  }

  void writeWithNanBox(int reg, int bits32) =>
      writePair(reg, bits32, _NanBox.hiWord);

  int readNanUnboxed(int reg) =>
      readHi(reg) == _NanBox.hiWord ? readLo(reg) : _NanBox.canonicalNaN32;
}

class _Layout {
  static const regCount = 32;
  static const bytesPerReg = 8;
  static const hiOffset = 4;
  static const byteCount = regCount * bytesPerReg;
}

class _Bits {
  static const word = 32;
}

class _Mask {
  static const word = 0xFFFFFFFF;
}

class _NanBox {
  static const hiWord = 0xFFFFFFFF;
  static const canonicalNaN32 = 0x7FC00000;
}
