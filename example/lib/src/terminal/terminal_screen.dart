import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:dart_emu_example/src/crt/crt_effect_widget.dart';
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

class _CrtToggleLayout {
  static const right = 8.0;
  static const top = 8.0;
  static const iconSize = 18.0;
  static const fontSize = 12.0;
  static const horizontalPadding = 10.0;
  static const verticalPadding = 6.0;
  static const borderRadius = 16.0;
  static const backgroundOpacity = 0.7;
}

/// Displays the RISC-V emulator output in an interactive terminal.
class TerminalScreen extends StatefulWidget {
  /// Creates the terminal screen for the given [config].
  const TerminalScreen({
    required this.config,
    this.useBundledDemoAssets = false,
    this.initialCrtEffect,
    this.onStopped,
    super.key,
  });

  /// The resolved machine configuration to boot.
  final MachineConfig config;

  /// If true, boot built-in bundled demo assets for this config's architecture.
  final bool useBundledDemoAssets;

  /// If set, start with this CRT effect mode instead of off.
  final CrtEffect? initialCrtEffect;

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

  ui.FragmentShader? _crtShader;
  late CrtEffect _crtEffect = widget.initialCrtEffect ?? CrtEffect.none;

  late final double _charWidthAtReference = _measureCharWidth();

  @override
  void initState() {
    super.initState();
    _launchEmulator();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/crt.frag');
      if (!mounted) return;
      setState(() => _crtShader = program.fragmentShader());
    } catch (e) {
      debugPrint('Failed to load CRT shader: $e');
    }
  }

  void _toggleCrtEffect() {
    setState(() {
      _crtEffect = _crtEffect.next();
    });
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
            EmulatorStatus.running || EmulatorStatus.stopped => Stack(
              children: [
                CrtEffectWidget(
                  shader: _crtShader,
                  effect: _crtEffect,
                  child: TerminalView(
                    _terminal,
                    autofocus: true,
                    hardwareKeyboardOnly: _isDesktopPlatform,
                    textStyle: TerminalStyle(
                      fontSize: fontSize,
                      fontFamily: _TerminalLayout.fontFamily,
                      fontFamilyFallback: _TerminalLayout.fontFamilyFallback,
                    ),
                  ),
                ),
                if (_crtShader != null) _buildCrtToggle(),
              ],
            ),
          };
        },
      ),
    );
  }

  Widget _buildCrtToggle() {
    return Positioned(
      right: _CrtToggleLayout.right,
      top: _CrtToggleLayout.top,
      child: GestureDetector(
        onTap: _toggleCrtEffect,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: _CrtToggleLayout.horizontalPadding,
            vertical: _CrtToggleLayout.verticalPadding,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(
              alpha: _CrtToggleLayout.backgroundOpacity,
            ),
            borderRadius: BorderRadius.circular(_CrtToggleLayout.borderRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.tv,
                color: Colors.white70,
                size: _CrtToggleLayout.iconSize,
              ),
              const SizedBox(width: 4),
              Text(
                'CRT: ${_crtEffect.label}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: _CrtToggleLayout.fontSize,
                ),
              ),
            ],
          ),
        ),
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
