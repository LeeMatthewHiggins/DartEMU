import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:dart_emu_example/src/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';

/// Root application widget for the DartEMU terminal UI.
class App extends StatefulWidget {
  /// Creates the application.
  ///
  /// When [bootXlen] is provided, the config picker is skipped and the
  /// bundled demo boots immediately. Use `?boot=32` or `?boot=64` in the
  /// URL on web. Use `?crt=full|flat|glass|off` to set the CRT effect.
  const App({this.bootXlen, this.initialCrtEffect, super.key});

  /// If set, skip the config picker and boot this architecture directly.
  final Xlen? bootXlen;

  /// If set, start the terminal with this CRT effect mode.
  final CrtEffect? initialCrtEffect;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  MachineConfig? _config;
  late Xlen? _demoXlen = widget.bootXlen;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartEMU',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: _buildHome(),
    );
  }

  void _reset() {
    setState(() {
      _config = null;
      _demoXlen = null;
    });
  }

  Widget _buildHome() {
    if (_config != null) {
      return TerminalScreen(
        config: _config!,
        initialCrtEffect: widget.initialCrtEffect,
        onStopped: _reset,
      );
    }
    if (_demoXlen != null) {
      return TerminalScreen(
        config: MachineConfig(xlen: _demoXlen!),
        useBundledDemoAssets: true,
        initialCrtEffect: widget.initialCrtEffect,
        onStopped: _reset,
      );
    }
    return ConfigPickerScreen(
      onConfigLoaded: (config) => setState(() => _config = config),
      onDemoSelected: (xlen) => setState(() => _demoXlen = xlen),
    );
  }
}
