enum RoundingMode {
  rne(0),
  rtz(1),
  rdn(2),
  rup(3),
  rmm(4);

  const RoundingMode(this.value);
  final int value;

  static RoundingMode fromValue(int v) => RoundingMode.values[v];
}

class FpFlags {
  const FpFlags._();

  static const int inexact = 1 << 0;
  static const int underflow = 1 << 1;
  static const int overflow = 1 << 2;
  static const int divideByZero = 1 << 3;
  static const int invalidOp = 1 << 4;
}

class FpFlagsAccumulator {
  int flags = 0;

  void add(int flag) => flags |= flag;

  void reset() => flags = 0;
}
