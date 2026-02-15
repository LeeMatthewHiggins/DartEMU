/// Web-safe stubs for 64-bit integer constants.
///
/// These values are never reached at runtime because the web build
/// only supports RV32, and all code paths referencing these constants
/// are guarded by RV64-only checks.
class Int64Const {
  static const signBit = 0;
  static const nanBoxMask = 0;
  static const maxSigned = 0;
  static const minSigned = 0;

  static const f64ExpMask = 0;
  static const f64MantMask = 0;
  static const f64QNanBit = 0;
  static const f64CanonicalNaN = 0;
}
