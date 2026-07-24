/// 64-bit integer constants that exceed the JavaScript safe integer range.
///
/// On native platforms these are compile-time constants.
/// On web this file is replaced by a stub via conditional import.
class Int64Const {
  static const int signBit = 1 << 63;
  static const nanBoxMask = 0xFFFFFFFF00000000;
  static const maxSigned = 0x7FFFFFFFFFFFFFFF;
  static const minSigned = -0x8000000000000000;

  static const f64ExpMask = 0x7FF0000000000000;
  static const f64MantMask = 0x000FFFFFFFFFFFFF;
  static const f64QNanBit = 0x0008000000000000;
  static const f64CanonicalNaN = 0x7FF8000000000000;
}
