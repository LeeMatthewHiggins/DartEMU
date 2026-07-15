class BitUtils {
  const BitUtils._();

  static int ctz32(int value) {
    if (value == 0) return 32;
    var v = value & _mask32;
    var n = 0;
    if ((v & 0x0000FFFF) == 0) {
      n += 16;
      v >>>= 16;
    }
    if ((v & 0x000000FF) == 0) {
      n += 8;
      v >>>= 8;
    }
    if ((v & 0x0000000F) == 0) {
      n += 4;
      v >>>= 4;
    }
    if ((v & 0x00000003) == 0) {
      n += 2;
      v >>>= 2;
    }
    if ((v & 0x00000001) == 0) {
      n += 1;
    }
    return n;
  }

  static int clz32(int value) {
    if (value == 0) return 32;
    var v = value & _mask32;
    var n = 0;
    if ((v & 0xFFFF0000) == 0) {
      n += 16;
      v <<= 16;
    }
    if ((v & 0xFF000000) == 0) {
      n += 8;
      v <<= 8;
    }
    if ((v & 0xF0000000) == 0) {
      n += 4;
      v <<= 4;
    }
    if ((v & 0xC0000000) == 0) {
      n += 2;
      v <<= 2;
    }
    if ((v & 0x80000000) == 0) {
      n += 1;
    }
    return n;
  }

  static int clz64(int value) {
    if (value == 0) return 64;
    final hi = (value >> _wordBits) & _mask32;
    if (hi != 0) return clz32(hi);
    return _wordBits + clz32(value & _mask32);
  }

  static int signExtend32(int value) {
    final masked = value & _mask32;
    if ((masked & _bit31) != 0) {
      return masked | _upperBits;
    }
    return masked;
  }

  static const int _mask32 = 0xFFFFFFFF;
  static const int _bit31 = 1 << 31;
  static const int _wordBits = 32;
  static const int _upperBits = ~_mask32;
}
