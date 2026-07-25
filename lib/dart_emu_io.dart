/// Platform-dependent extensions for dart_emu that require `dart:io`.
///
/// Provides file-based configuration loading and file-backed block devices.
/// Use `package:dart_emu/dart_emu.dart` for the platform-independent API.
library;

export 'dart_emu.dart';
export 'src/device/file_block_device.dart';
export 'src/device/virtio/ninep/ninep_directory_backend.dart';
export 'src/machine/config_loader.dart';
