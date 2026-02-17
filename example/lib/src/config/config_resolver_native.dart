import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu_io.dart';

/// Whether file-based config loading is available on this platform.
bool get isConfigPickerSupported => true;

/// Loads a YAML config file and resolves all paths to in-memory data.
MachineConfig loadAndResolveConfig(String filePath) {
  final config = ConfigLoader.loadFromFile(filePath);
  return ConfigResolver.resolve(config);
}

/// Reads raw bytes from a file path.
Uint8List readFileBytes(String filePath) => File(filePath).readAsBytesSync();
