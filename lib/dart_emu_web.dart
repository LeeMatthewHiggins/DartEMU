/// Web-only extensions for dart_emu that use browser APIs.
///
/// Provides a File System Access picker that loads a user-chosen host
/// directory into an in-memory VirtIO-9P share. Use
/// `package:dart_emu/dart_emu.dart` for the platform-independent API and
/// `package:dart_emu/dart_emu_io.dart` for native filesystem access.
library;

export 'dart_emu.dart';
export 'src/device/virtio/ninep/ninep_web_picker.dart';
