import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:dart_emu_example/src/crt/crt_effect_widget.dart';
import 'package:dart_emu_example/src/emulator/emulator_controller.dart';
import 'package:dart_emu_example/src/terminal/demo_terminal_view.dart';
import 'package:dart_emu_example/src/terminal/greeting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class _TerminalLayout {
  static const standardColumns = 80;
  static const referenceFontSize = 16.0;
  static const minFontSize = 8.0;
  static const maxFontSize = 24.0;
  /// Bundled with the app rather than asked of the system.
  ///
  /// The web build resolves only the fonts declared in pubspec.yaml, so a
  /// system name like Menlo silently became proportional Roboto — and a
  /// terminal lays out fixed cells, so every glyph was padded to a width it
  /// did not fill.
  static const fontFamily = 'JetBrainsMonoNL';

  /// Still listed, for a build where the asset somehow does not load.
  static const fontFamilyFallback = [
    'Menlo',
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
    this.guestUserland,
    this.sharedFolders = const [],
    this.onReloadShare,
    this.initialCrtEffect,
    this.onStopped,
    super.key,
  });

  /// The resolved machine configuration to boot.
  final MachineConfig config;

  /// If true, boot built-in bundled demo assets for this config's architecture.
  final bool useBundledDemoAssets;

  /// What the guest runs, shown in the banner. Defaults to a description
  /// inferred from the architecture.
  final String? guestUserland;

  /// VirtIO-9P shares to expose and auto-mount once the shell is ready.
  ///
  /// Only used together with [useBundledDemoAssets]; each is mounted at
  /// `/mnt/<tag>` when the first shell prompt appears.
  final List<NinePShare> sharedFolders;

  /// Re-reads the mounted share to pull in host-side changes, or `null`
  /// when no refreshable share is mounted. Surfaces a "Reload" control.
  final Future<void> Function()? onReloadShare;

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
  final _terminalController = TerminalController();

  /// Owned here so a tap can restore focus even when it lands on an
  /// existing selection, which xterm clears without refocusing.
  final _terminalFocusNode = FocusNode();

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
    // The terminal has its own right-click menu; without this the browser
    // draws its own on top of it.
    if (kIsWeb) {
      unawaited(BrowserContextMenu.disableContextMenu());
    }
    _launchEmulator();
    _loadShader();
    _startAutoRefresh();
  }

  /// Periodically re-syncs the mounted share so host-side changes reach the
  /// guest without a manual reload. The sync is mtime-diffed, so an
  /// unchanged folder costs only a directory walk.
  void _startAutoRefresh() {
    if (widget.onReloadShare == null) return;
    _reloadTimer = Timer.periodic(_autoRefreshInterval, (_) {
      unawaited(_refreshShare());
    });
  }

  Timer? _reloadTimer;
  var _refreshInFlight = false;

  Future<void> _refreshShare() async {
    final reload = widget.onReloadShare;
    if (reload == null || _refreshInFlight) return;
    _refreshInFlight = true;
    try {
      await reload();
    } on Object catch (e) {
      debugPrint('Share refresh failed: $e');
    } finally {
      _refreshInFlight = false;
    }
  }

  static const _autoRefreshInterval = Duration(seconds: 3);

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
    // Branded banner first, so the terminal is never blank while the
    // guest boots (and the demo is identifiable when embedded).
    _terminal.write(
      dartEmuGreeting(widget.config.xlen, userland: widget.guestUserland),
    );

    _statusSub = _controller!.status.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      if (status == EmulatorStatus.stopped) {
        widget.onStopped?.call();
      }
    });

    _outputSub = _controller!.output.listen((bytes) {
      _terminal.write(utf8.decode(bytes, allowMalformed: true));
      _maybeAutoMount(utf8.decode(bytes, allowMalformed: true));
    });

    if (widget.useBundledDemoAssets) {
      await _controller!.start(
        xlen: widget.config.xlen,
        sharedFolders: widget.sharedFolders,
      );
    } else {
      await _controller!.startWithConfig(widget.config);
    }
  }

  final StringBuffer _bootTail = StringBuffer();
  var _mounted9p = false;

  /// Sends the 9P mount command(s) once the first shell prompt appears, so
  /// the demo lands with the shared folders already mounted at `/mnt/<tag>`.
  void _maybeAutoMount(String chunk) {
    if (_mounted9p || widget.sharedFolders.isEmpty) return;
    _bootTail.write(chunk);
    final tail = _bootTail.toString();
    if (!tail.contains(_shellPrompt)) return;
    _mounted9p = true;
    for (final share in widget.sharedFolders) {
      final tag = share.tag;
      _controller?.sendInput(
        'mkdir -p /mnt/$tag && '
        'mount -t 9p -o trans=virtio,version=9p2000.u,msize=65536 '
        '$tag /mnt/$tag && '
        'echo "[9p] $tag mounted at /mnt/$tag" && ls -la /mnt/$tag\n',
      );
    }
  }

  static const _shellPrompt = '# ';

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
    if (kIsWeb) {
      unawaited(BrowserContextMenu.enableContextMenu());
    }
    _reloadTimer?.cancel();
    _outputSub?.cancel();
    _statusSub?.cancel();
    _controller?.dispose();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
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
                  child: DemoTerminalView(
                    terminal: _terminal,
                    controller: _terminalController,
                    focusNode: _terminalFocusNode,
                    hardwareKeyboardOnly: _isDesktopPlatform,
                    textStyle: TerminalStyle(
                      fontSize: fontSize,
                      fontFamily: _TerminalLayout.fontFamily,
                      fontFamilyFallback: _TerminalLayout.fontFamilyFallback,
                    ),
                  ),
                ),
                if (_crtShader != null) _buildCrtToggle(),
                if (widget.onReloadShare != null) _buildReloadButton(),
              ],
            ),
          };
        },
      ),
    );
  }

  Widget _buildReloadButton() {
    return Positioned(
      left: _CrtToggleLayout.right,
      top: _CrtToggleLayout.top,
      child: GestureDetector(
        onTap: _reloading ? null : _reloadShare,
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
              Icon(
                _reloading ? Icons.hourglass_top : Icons.sync,
                color: Colors.white70,
                size: _CrtToggleLayout.iconSize,
              ),
              const SizedBox(width: 4),
              const Text(
                'Reload folder',
                style: TextStyle(
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

  var _reloading = false;

  /// Forces a re-sync now, then re-lists the share in the guest so the
  /// refreshed contents are visible (v9fs runs uncached, so the next read
  /// reflects the updated backend). Auto-refresh already keeps the backend
  /// current; this is the "show me now" action.
  Future<void> _reloadShare() async {
    if (widget.onReloadShare == null || _reloading) return;
    setState(() => _reloading = true);
    await _refreshShare();
    if (mounted) setState(() => _reloading = false);
    if (widget.sharedFolders.isNotEmpty) {
      final tag = widget.sharedFolders.first.tag;
      _controller?.sendInput('ls -la /mnt/$tag\n');
    }
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
