import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:dart_emu_example/src/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';

/// Root application widget for the DartEMU terminal UI.
class App extends StatefulWidget {
  /// Creates the application.
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  MachineConfig? _config;
  Xlen? _demoXlen;

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
      return TerminalScreen(config: _config!, onStopped: _reset);
    }
    if (_demoXlen != null) {
      return TerminalScreen(
        config: MachineConfig(xlen: _demoXlen!),
        useBundledDemoAssets: true,
        onStopped: _reset,
      );
    }
    return ConfigPickerScreen(
      onConfigLoaded: (config) => setState(() => _config = config),
      onDemoSelected: (xlen) => setState(() => _demoXlen = xlen),
    );
  }
}
