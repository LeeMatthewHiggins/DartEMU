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

  EmulatorController? _controller;
  StreamSubscription<List<int>>? _outputSub;
  StreamSubscription<EmulatorStatus>? _statusSub;
  EmulatorStatus _status = EmulatorStatus.idle;
  Xlen? _selectedXlen;

  late final double _charWidthAtReference = _measureCharWidth();

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _launchEmulator(Xlen.rv32);
    }
  }

  void _launchEmulator(Xlen xlen) {
    setState(() {
      _selectedXlen = xlen;
      _status = EmulatorStatus.idle;
    });

    _controller = EmulatorController();
    _terminal.onOutput = _controller!.sendInput;
    _startEmulator(xlen);
  }

  Future<void> _startEmulator(Xlen xlen) async {
    _statusSub = _controller!.status.listen((status) {
      if (mounted) setState(() => _status = status);
    });

    _outputSub = _controller!.output.listen((bytes) {
      _terminal.write(utf8.decode(bytes, allowMalformed: true));
    });

    await _controller!.start(xlen: xlen);
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
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedXlen == null) {
      return _buildChooser();
    }
    return _buildTerminal();
  }

  Widget _buildChooser() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('DartEMU'),
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Select architecture',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: _ChooserLayout.spacing),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ArchCard(
                  label: 'RISC-V 64-bit',
                  subtitle: 'RV64IMAFDC',
                  onTap: () => _launchEmulator(Xlen.rv64),
                ),
                const SizedBox(width: _ChooserLayout.spacing),
                _ArchCard(
                  label: 'RISC-V 32-bit',
                  subtitle: 'RV32IMAFDC',
                  onTap: () => _launchEmulator(Xlen.rv32),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTerminal() {
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

  String get _appBarTitle {
    final arch = switch (_selectedXlen) {
      Xlen.rv32 => 'RV32',
      Xlen.rv64 => 'RV64',
      null => '',
    };

    return switch (_status) {
      EmulatorStatus.idle => 'DartEMU $arch',
      EmulatorStatus.starting => 'DartEMU $arch — Booting...',
      EmulatorStatus.running => 'DartEMU $arch — Running',
      EmulatorStatus.stopped => 'DartEMU $arch — Stopped',
      EmulatorStatus.error => 'DartEMU $arch — Error',
    };
  }
}

class _ErrorLayout {
  static const padding = 24.0;
}

class _ChooserLayout {
  static const spacing = 24.0;
  static const cardWidth = 180.0;
  static const cardPadding = 24.0;
  static const subtitleSpacing = 8.0;
}

class _ArchCard extends StatelessWidget {
  const _ArchCard({
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ChooserLayout.cardWidth,
      child: Card(
        color: Colors.grey.shade900,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(_ChooserLayout.cardPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: _ChooserLayout.subtitleSpacing),
                Text(
                  subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
