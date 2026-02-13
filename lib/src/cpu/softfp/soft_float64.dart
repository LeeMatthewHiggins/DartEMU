import 'package:dart_emu/src/cpu/softfp/soft_float.dart';

class SoftFloat64 {
  const SoftFloat64._();

  static int add(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int sub(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int mul(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int div(int a, int b, RoundingMode rm, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int sqrt(int a, RoundingMode rm, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int fma(
    int a,
    int b,
    int c,
    RoundingMode rm,
    FpFlagsAccumulator flags,
  ) {
    throw UnimplementedError();
  }

  static int classify(int a) {
    throw UnimplementedError();
  }

  static bool eq(int a, int b, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static bool lt(int a, int b, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static bool le(int a, int b, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int min(int a, int b, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }

  static int max(int a, int b, FpFlagsAccumulator flags) {
    throw UnimplementedError();
  }
}
