import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/app.dart';
import 'package:flutter/material.dart';

void main() {
  final bootXlen = _parseBootParam();
  runApp(App(bootXlen: bootXlen));
}

/// Reads the `boot` query parameter from the URL (web only).
///
/// Supports `?boot=32` and `?boot=64`. Returns null if absent or
/// on non-web platforms.
Xlen? _parseBootParam() {
  final param = Uri.base.queryParameters['boot'];
  return switch (param) {
    '32' => Xlen.rv32,
    '64' => Xlen.rv64,
    _ => null,
  };
}
