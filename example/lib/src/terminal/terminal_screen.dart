import 'dart:async';
import 'dart:convert';
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
  static const fontFamily = 'Menlo';
  static const fontFamilyFallback = [
    'Consolas',
    'DejaVu Sans Mono',
    'Liberation Mono',
    'monospace',
  ];
}

class _ErrorLayout {
  static const padding = 24.0;
}

/// Displays the RISC-V emulator output in an interactive terminal.
class TerminalScreen extends StatefulWidget {
  /// Creates the terminal screen for the given [config].
  const TerminalScreen({
    required this.config,
    this.useBundledDemoAssets = false,
    this.onStopped,
    super.key,
  });

  /// The resolved machine configuration to boot.
  final MachineConfig config;

  /// If true, boot built-in bundled demo assets for this config's architecture.
  final bool useBundledDemoAssets;

  /// Called when the guest OS shuts down or reboots.
  final VoidCallback? onStopped;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with TickerProviderStateMixin {
  final _terminal = Terminal(maxLines: 10000);

  EmulatorController? _controller;
  StreamSubscription<List<int>>? _outputSub;
  StreamSubscription<EmulatorStatus>? _statusSub;
  EmulatorStatus _status = EmulatorStatus.idle;

  late final double _charWidthAtReference = _measureCharWidth();

  @override
  void initState() {
    super.initState();
    _launchEmulator();
  }

  void _launchEmulator() {
    _controller = EmulatorController(vsync: this);
    _terminal.onOutput = _controller!.sendInput;
    _startEmulator();
  }

  Future<void> _startEmulator() async {
    _statusSub = _controller!.status.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      if (status == EmulatorStatus.stopped) {
        widget.onStopped?.call();
      }
    });

    _outputSub = _controller!.output.listen((bytes) {
      _terminal.write(utf8.decode(bytes, allowMalformed: true));
    });

    if (widget.useBundledDemoAssets) {
      await _controller!.start(xlen: widget.config.xlen);
    } else {
      await _controller!.startWithConfig(widget.config);
    }
  }

  double _measureCharWidth() {
    final painter = TextPainter(
      text: const TextSpan(
        text: 'W',
        style: TextStyle(
          fontFamily: _TerminalLayout.fontFamily,
          fontFamilyFallback: _TerminalLayout.fontFamilyFallback,
          fontSize: _TerminalLayout.referenceFontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    return painter.width;
  }

  double _fontSizeForWidth(double availableWidth) {
    final scaleFactor =
        availableWidth /
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
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = _fontSizeForWidth(constraints.maxWidth);

          return switch (_status) {
            EmulatorStatus.idle || EmulatorStatus.starting => const Center(
              child: CircularProgressIndicator(),
            ),
            EmulatorStatus.error => Center(
              child: Padding(
                padding: const EdgeInsets.all(_ErrorLayout.padding),
                child: SelectableText(
                  'Emulator error:\n${_controller?.lastError}',
                  style: const TextStyle(
                    color: Colors.red,
                    fontFamily: _TerminalLayout.fontFamily,
                  ),
                ),
              ),
            ),
            EmulatorStatus.running || EmulatorStatus.stopped => TerminalView(
              _terminal,
              autofocus: true,
              hardwareKeyboardOnly: _isDesktopPlatform,
              textStyle: TerminalStyle(
                fontSize: fontSize,
                fontFamily: _TerminalLayout.fontFamily,
                fontFamilyFallback: _TerminalLayout.fontFamilyFallback,
              ),
            ),
          };
        },
      ),
    );
  }

  bool get _isDesktopPlatform => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };
}
