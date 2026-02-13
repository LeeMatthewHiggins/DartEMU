import 'dart:typed_data';

extension ByteDataLe on ByteData {
  int getLeUint16(int offset) => getUint16(offset, Endian.little);
  int getLeUint32(int offset) => getUint32(offset, Endian.little);
  int getLeUint64(int offset) => getUint64(offset, Endian.little);
  int getLeInt32(int offset) => getInt32(offset, Endian.little);
  int getLeInt64(int offset) => getInt64(offset, Endian.little);

  void setLeUint16(int offset, int value) =>
      setUint16(offset, value, Endian.little);
  void setLeUint32(int offset, int value) =>
      setUint32(offset, value, Endian.little);
  void setLeUint64(int offset, int value) =>
      setUint64(offset, value, Endian.little);
}

extension ByteDataBe on ByteData {
  int getBeUint16(int offset) => getUint16(offset);
  int getBeUint32(int offset) => getUint32(offset);
  int getBeUint64(int offset) => getUint64(offset);

  void setBeUint16(int offset, int value) => setUint16(offset, value);
  void setBeUint32(int offset, int value) => setUint32(offset, value);
  void setBeUint64(int offset, int value) => setUint64(offset, value);
}
