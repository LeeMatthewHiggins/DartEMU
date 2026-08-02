import 'package:flutter/foundation.dart';

class _Backend {
  /// Set by the compiler when the build target is WasmGC.
  static const isWasm = bool.fromEnvironment('dart.tool.dart2wasm');
}

/// Whether this build can run RV64 guests.
///
/// RV64 needs the 64-bit register file, which is an `Int64List` — available
/// everywhere except the JavaScript web backend, where constructing one
/// throws. The deployed demo ships WasmGC with a JavaScript fallback, so a
/// browser without WasmGC support gets a build where RV64 must be kept out
/// of reach rather than crashing on boot.
const bool isRv64Supported = !kIsWeb || _Backend.isWasm;

/// Shown wherever an RV64 action is unavailable on this build.
const String rv64UnsupportedMessage =
    'RV64 needs WebAssembly (WasmGC), and this browser is running the '
    'JavaScript build. RV32 guests still work.';
