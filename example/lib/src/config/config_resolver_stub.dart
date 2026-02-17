import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';

/// Whether file-based config loading is available on this platform.
bool get isConfigPickerSupported => false;

/// Stub for web — file-based config resolution is not supported.
MachineConfig loadAndResolveConfig(String filePath) {
  throw UnsupportedError('File-based config loading is not available on web');
}

/// Stub for web — file reading is not supported.
Uint8List readFileBytes(String filePath) {
  throw UnsupportedError('File reading is not available on web');
}
