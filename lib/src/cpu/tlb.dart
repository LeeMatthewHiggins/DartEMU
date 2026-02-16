import 'dart:typed_data';

class TlbEntry {
  int virtualTag = _invalidTag;
  ByteData hostData = _emptyData;
  int hostOffset = 0;

  void invalidate() {
    virtualTag = _invalidTag;
    hostData = _emptyData;
    hostOffset = 0;
  }

  static const _invalidTag = -1;
  static final ByteData _emptyData = ByteData(0);
}

class TlbConstants {
  const TlbConstants._();

  static const size = 256;
  static const indexMask = size - 1;
  static const pageSizeLog2 = 12;
  static const pageSize = 1 << pageSizeLog2;
  static const pageMask = pageSize - 1;
}
