import 'dart:typed_data';

extension ByteDataLe on ByteData {
  int getLeUint16(int offset) => getUint16(offset, Endian.little);
  int getLeUint32(int offset) => getUint32(offset, Endian.little);
  int getLeInt32(int offset) => getInt32(offset, Endian.little);

  int getLeUint64(int offset) {
    final lo = getUint32(offset, Endian.little);
    final hi = getUint32(offset + _ByteConst.wordBytes, Endian.little);
    return lo | (hi << _ByteConst.wordBits);
  }

  int getLeInt64(int offset) => getLeUint64(offset);

  void setLeUint16(int offset, int value) =>
      setUint16(offset, value, Endian.little);
  void setLeUint32(int offset, int value) =>
      setUint32(offset, value, Endian.little);

  void setLeUint64(int offset, int value) {
    setUint32(offset, value & _ByteConst.mask32, Endian.little);
    setUint32(
      offset + _ByteConst.wordBytes,
      (value >> _ByteConst.wordBits) & _ByteConst.mask32,
      Endian.little,
    );
  }
}

extension ByteDataBe on ByteData {
  int getBeUint16(int offset) => getUint16(offset);
  int getBeUint32(int offset) => getUint32(offset);

  int getBeUint64(int offset) {
    final hi = getUint32(offset);
    final lo = getUint32(offset + _ByteConst.wordBytes);
    return lo | (hi << _ByteConst.wordBits);
  }

  void setBeUint16(int offset, int value) => setUint16(offset, value);
  void setBeUint32(int offset, int value) => setUint32(offset, value);

  void setBeUint64(int offset, int value) {
    setUint32(
      offset,
      (value >> _ByteConst.wordBits) & _ByteConst.mask32,
    );
    setUint32(offset + _ByteConst.wordBytes, value & _ByteConst.mask32);
  }
}

class _ByteConst {
  static const wordBits = 32;
  static const wordBytes = 4;
  static const mask32 = 0xFFFFFFFF;
}
