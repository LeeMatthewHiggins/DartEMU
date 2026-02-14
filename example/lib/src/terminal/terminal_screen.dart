import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/emulator/emulator_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class _TerminalLayout {
  static const standardColumns = 80;
  static const referenceFontSize = 16.0;
  static const minFontSize = 8.0;
  static const maxFontSize = 24.0;
  static const fontFamily = 'monospace';
}

/// Displays the RISC-V emulator output in an interactive terminal.
class TerminalScreen extends StatefulWidget {
  /// Creates the terminal screen.
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = EmulatorController();

  StreamSubscription<List<int>>? _outputSub;
  StreamSubscription<EmulatorStatus>? _statusSub;
  EmulatorStatus _status = EmulatorStatus.idle;

  late final double _charWidthAtReference = _measureCharWidth();

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _controller.sendInput;
    _startEmulator();
  }

  Future<void> _startEmulator() async {
    _statusSub = _controller.status.listen((status) {
      if (mounted) setState(() => _status = status);
    });

    _outputSub = _controller.output.listen((bytes) {
      _terminal.write(utf8.decode(bytes, allowMalformed: true));
    });

    await _controller.start();
  }

  double _measureCharWidth() {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontFamily: _TerminalLayout.fontFamily,
        fontSize: _TerminalLayout.referenceFontSize,
      ),
    )..addText('W');

    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));

    return paragraph.maxIntrinsicWidth;
  }

  double _fontSizeForWidth(double availableWidth) {
    final scaleFactor = availableWidth /
        (_TerminalLayout.standardColumns * _charWidthAtReference);
    final fontSize = _TerminalLayout.referenceFontSize * scaleFactor;
    return fontSize.clamp(
      _TerminalLayout.minFontSize,
      _TerminalLayout.maxFontSize,
    );
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _statusSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_appBarTitle),
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = _fontSizeForWidth(constraints.maxWidth);

          return switch (_status) {
            EmulatorStatus.idle ||
            EmulatorStatus.starting =>
              const Center(child: CircularProgressIndicator()),
            EmulatorStatus.error => Center(
                child: Text(
                  'Emulator error: ${_controller.currentStatus}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            EmulatorStatus.running ||
            EmulatorStatus.stopped =>
              TerminalView(
                _terminal,
                autofocus: true,
                hardwareKeyboardOnly: _isDesktopPlatform,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
          };
        },
      ),
    );
  }

  bool get _isDesktopPlatform => switch (defaultTargetPlatform) {
        TargetPlatform.macOS ||
        TargetPlatform.linux ||
        TargetPlatform.windows =>
          true,
        _ => false,
      };

  String get _appBarTitle => switch (_status) {
        EmulatorStatus.idle => 'DartEMU',
        EmulatorStatus.starting => 'DartEMU — Booting...',
        EmulatorStatus.running => 'DartEMU — Running',
        EmulatorStatus.stopped => 'DartEMU — Stopped',
        EmulatorStatus.error => 'DartEMU — Error',
      };
}
