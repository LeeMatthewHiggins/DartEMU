import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/agentos/agentos_demo.dart';
import 'package:dart_emu_example/src/agentos/api_key_dialog.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:dart_emu_example/src/config/rv64_support.dart';
import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:dart_emu_example/src/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';

/// Root application widget for the DartEMU terminal UI.
class App extends StatefulWidget {
  /// Creates the application.
  ///
  /// When [bootXlen] is provided, the config picker is skipped and the
  /// bundled demo boots immediately. Use `?boot=32` or `?boot=64` in the
  /// URL on web. Use `?crt=full|flat|glass|off` to set the CRT effect,
  /// and `?bundle=<url>` to preload a `.zip` VM bundle into the picker.
  const App({this.bootXlen, this.initialCrtEffect, this.bundleUrl, super.key});

  /// If set, skip the config picker and boot this architecture directly.
  final Xlen? bootXlen;

  /// If set, start the terminal with this CRT effect mode.
  final CrtEffect? initialCrtEffect;

  /// If set, the picker downloads this `.zip` bundle and preloads it,
  /// leaving only the Boot button to press.
  final String? bundleUrl;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  MachineConfig? _config;
  late Xlen? _demoXlen = widget.bootXlen;
  List<NinePShare> _demoShares = const [];
  Future<void> Function()? _reloadShare;

  /// Credentials for the AgentOS demo, held here and never given to a guest.
  final _credentials = CredentialStore();

  /// Set when the machine being booted is not described by its architecture.
  String? _guestUserland;

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
      _demoShares = const [];
      _reloadShare = null;
      _guestUserland = null;
    });
  }

  /// Boots the agent machine, with the visitor's key held on this page.
  ///
  /// A visitor who supplies nothing still gets a working machine; its first
  /// request comes back refused, naming the credential it lacks.
  Future<void> _bootAgentOs(ApiKeyChoice choice) async {
    _credentials.set(AgentOsDemo.credentialName, choice.key);
    final config = await AgentOsDemo.buildConfig(_credentials);
    if (!mounted) return;
    setState(() {
      _config = config;
      _guestUserland = 'AgentOS';
    });
  }

  Widget _buildHome() {
    if (_config != null) {
      return TerminalScreen(
        config: _config!,
        guestUserland: _guestUserland,
        initialCrtEffect: widget.initialCrtEffect,
        onStopped: _reset,
      );
    }
    if (_demoXlen == Xlen.rv64 && !isRv64Supported) {
      // A ?boot=64 link opened in a browser without WasmGC would crash on
      // the 64-bit register file; landing on the picker is the kind option.
      _demoXlen = null;
    }
    if (_demoXlen != null) {
      return TerminalScreen(
        config: MachineConfig(xlen: _demoXlen!),
        useBundledDemoAssets: true,
        sharedFolders: _demoShares,
        onReloadShare: _reloadShare,
        initialCrtEffect: widget.initialCrtEffect,
        onStopped: _reset,
      );
    }
    return ConfigPickerScreen(
      prefillBundleUrl: widget.bundleUrl,
      onConfigLoaded: (config) => setState(() => _config = config),
      onDemoSelected: (xlen) => setState(() => _demoXlen = xlen),
      onAgentOsSelected: _bootAgentOs,
      onDemoWithShare: (xlen, share, refresh) => setState(() {
        _demoXlen = xlen;
        _demoShares = [share];
        _reloadShare = refresh;
      }),
    );
  }
}
