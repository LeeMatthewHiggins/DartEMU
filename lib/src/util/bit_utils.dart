class BitUtils {
  const BitUtils._();

  static int ctz32(int value) {
    if (value == 0) return 32;
    var count = 0;
    var v = value & _mask32;
    while ((v & 1) == 0) {
      count++;
      v >>= 1;
    }
    return count;
  }

  static int clz32(int value) {
    if (value == 0) return 32;
    var count = 0;
    var v = value & _mask32;
    while ((v & _bit31) == 0) {
      count++;
      v <<= 1;
    }
    return count;
  }

  static int clz64(int value) {
    if (value == 0) return 64;
    var count = 0;
    var v = value;
    while ((v & _bit63) == 0) {
      count++;
      v <<= 1;
    }
    return count;
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
  static const int _bit63 = 1 << 63;
  static const int _upperBits = ~_mask32;
}
