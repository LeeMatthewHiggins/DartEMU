import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/app.dart';
import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:flutter/material.dart';

void main() {
  final params = Uri.base.queryParameters;
  runApp(
    App(
      bootXlen: _parseBootParam(params),
      initialCrtEffect: _parseCrtParam(params),
    ),
  );
}

Xlen? _parseBootParam(Map<String, String> params) {
  return switch (params['boot']) {
    '32' => Xlen.rv32,
    '64' => Xlen.rv64,
    _ => null,
  };
}

CrtEffect? _parseCrtParam(Map<String, String> params) {
  return switch (params['crt']) {
    'full' => CrtEffect.full,
    'flat' => CrtEffect.flat,
    'glass' => CrtEffect.glass,
    'off' => CrtEffect.none,
    _ => null,
  };
}
