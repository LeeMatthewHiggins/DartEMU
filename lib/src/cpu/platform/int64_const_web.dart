/// dart2js-safe stubs for 64-bit integer constants.
///
/// Selected only for the JavaScript backend (via `dart.library.html`),
/// which cannot represent integer literals above 2^53. The WasmGC
/// backend has native 64-bit integers and uses the real constants,
/// which RV64 emulation and double-precision soft-float require.
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
