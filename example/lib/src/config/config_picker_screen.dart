import 'dart:async';

import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/config/config_resolver_adapter.dart'
    as resolver;
import 'package:dart_emu_example/src/config/config_summary_card.dart';
import 'package:dart_emu_example/src/config/drop_target_area.dart';
import 'package:dart_emu_example/src/config/zip_config_loader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class _PickerLayout {
  static const iconSize = 56.0;
  static const spacing = 16.0;
  static const smallSpacing = 8.0;
  static const maxContentWidth = 420.0;
  static const errorPadding = 12.0;
  static const dividerIndent = 48.0;
}

class _FileFilter {
  static const yamlExtensions = ['yaml', 'yml'];
  static const zipExtensions = ['zip'];
  static const allExtensions = [...yamlExtensions, ...zipExtensions];
  static const dialogTitle = 'Select VM Configuration';
}

/// Landing screen where the user can drop or browse for a VM config.
///
/// Accepts `.zip` bundles on all platforms (including web) and
/// `.yaml` files on desktop where file-path resolution is available.
class ConfigPickerScreen extends StatefulWidget {
  /// Creates the config picker screen.
  const ConfigPickerScreen({
    required this.onConfigLoaded,
    required this.onDemoSelected,
    super.key,
  });

  /// Called with a resolved [MachineConfig] when a config is loaded.
  final ValueChanged<MachineConfig> onConfigLoaded;

  /// Called with the selected [Xlen] when a built-in demo is chosen.
  final ValueChanged<Xlen> onDemoSelected;

  @override
  State<ConfigPickerScreen> createState() => _ConfigPickerScreenState();
}

class _ConfigPickerScreenState extends State<ConfigPickerScreen> {
  MachineConfig? _parsedConfig;
  String? _errorMessage;
  bool _loading = false;

  bool get _canUseFilePaths => resolver.isConfigPickerSupported;

  List<String> get _allowedExtensions =>
      _canUseFilePaths ? _FileFilter.allExtensions : _FileFilter.zipExtensions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _PickerLayout.maxContentWidth,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(_PickerLayout.spacing),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_canUseFilePaths)
                  _buildDropZone()
                else
                  _buildBrowseSection(),
                if (_loading) ...[
                  const SizedBox(height: _PickerLayout.spacing),
                  const CircularProgressIndicator(),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: _PickerLayout.spacing),
                  _buildError(),
                ],
                if (_parsedConfig != null) ...[
                  const SizedBox(height: _PickerLayout.spacing),
                  _buildConfigResult(),
                ],
                const SizedBox(height: _PickerLayout.spacing),
                _buildDemoDivider(),
                const SizedBox(height: _PickerLayout.spacing),
                _buildDemoSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDropZone() {
    return DropTargetArea(
      onFileDropped: _handleFilePath,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.file_open_outlined,
            size: _PickerLayout.iconSize,
            color: Colors.grey.shade500,
          ),
          const SizedBox(height: _PickerLayout.spacing),
          Text(
            'Drop a .yaml or .zip config here',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: _PickerLayout.smallSpacing),
          Text(
            'or',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: _PickerLayout.smallSpacing),
          FilledButton.icon(
            onPressed: _loading ? null : _browseForConfig,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Browse...'),
          ),
        ],
      ),
    );
  }

  Widget _buildBrowseSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.file_open_outlined,
          size: _PickerLayout.iconSize,
          color: Colors.grey.shade500,
        ),
        const SizedBox(height: _PickerLayout.spacing),
        Text(
          'Load a .zip VM bundle',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: _PickerLayout.smallSpacing),
        FilledButton.icon(
          onPressed: _loading ? null : _browseForConfig,
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Browse...'),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(_PickerLayout.errorPadding),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        _errorMessage!,
        style: TextStyle(color: Colors.red.shade300, fontSize: 13),
      ),
    );
  }

  Widget _buildConfigResult() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConfigSummaryCard(config: _parsedConfig!),
        const SizedBox(height: _PickerLayout.spacing),
        FilledButton.icon(
          onPressed: () => widget.onConfigLoaded(_parsedConfig!),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Boot'),
        ),
      ],
    );
  }

  Widget _buildDemoDivider() {
    return Row(
      children: [
        const Expanded(
          child: Divider(indent: _PickerLayout.dividerIndent),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _PickerLayout.smallSpacing,
          ),
          child: Text(
            'or boot a built-in demo',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 12,
            ),
          ),
        ),
        const Expanded(
          child: Divider(endIndent: _PickerLayout.dividerIndent),
        ),
      ],
    );
  }

  Widget _buildDemoSection() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!kIsWeb)
          Padding(
            padding: const EdgeInsets.only(
              right: _PickerLayout.spacing,
            ),
            child: _DemoCard(
              label: 'RISC-V 64-bit',
              subtitle: 'RV64IMAFDC',
              onTap: () => widget.onDemoSelected(Xlen.rv64),
            ),
          ),
        _DemoCard(
          label: 'RISC-V 32-bit',
          subtitle: 'RV32IMAFDC',
          onTap: () => widget.onDemoSelected(Xlen.rv32),
        ),
      ],
    );
  }

  Future<void> _browseForConfig() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: _FileFilter.dialogTitle,
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;

    if (_isZipFile(file.name)) {
      final bytes = file.bytes;
      if (bytes == null) return;
      await _handleZipBytes(bytes);
    } else if (_canUseFilePaths && file.path != null) {
      _handleFilePath(file.path!);
    }
  }

  void _handleFilePath(String path) {
    if (_isZipFile(path)) {
      unawaited(_handleZipFilePath(path));
      return;
    }

    if (!_isYamlFile(path)) {
      _setError('Please select a .yaml or .zip file');
      return;
    }

    _setLoading();

    try {
      final config = resolver.loadAndResolveConfig(path);
      setState(() {
        _parsedConfig = config;
        _loading = false;
      });
    } on Object catch (e) {
      _setError(e.toString());
    }
  }

  Future<void> _handleZipFilePath(String path) async {
    _setLoading();
    await Future<void>.delayed(Duration.zero);

    try {
      final bytes = resolver.readFileBytes(path);
      _finishZipLoad(bytes);
    } on Object catch (e) {
      _setError(e.toString());
    }
  }

  Future<void> _handleZipBytes(Uint8List bytes) async {
    _setLoading();
    await Future<void>.delayed(Duration.zero);

    try {
      _finishZipLoad(bytes);
    } on Object catch (e) {
      _setError(e.toString());
    }
  }

  void _finishZipLoad(Uint8List bytes) {
    final config = ZipConfigLoader.load(bytes);
    if (!mounted) return;
    setState(() {
      _parsedConfig = config;
      _loading = false;
    });
  }

  void _setLoading() {
    setState(() {
      _loading = true;
      _errorMessage = null;
      _parsedConfig = null;
    });
  }

  void _setError(String message) {
    setState(() {
      _errorMessage = message;
      _parsedConfig = null;
      _loading = false;
    });
  }

  bool _isYamlFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.yaml') || lower.endsWith('.yml');
  }

  bool _isZipFile(String name) => name.toLowerCase().endsWith('.zip');
}

class _DemoCardLayout {
  static const width = 160.0;
  static const padding = 20.0;
  static const subtitleSpacing = 6.0;
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({
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
      width: _DemoCardLayout.width,
      child: Card(
        color: Colors.grey.shade900,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(_DemoCardLayout.padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: _DemoCardLayout.subtitleSpacing),
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
