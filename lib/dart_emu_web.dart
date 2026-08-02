/// Web-only extensions for dart_emu that use browser APIs.
///
/// Provides a File System Access picker that loads a user-chosen host
/// directory into an in-memory VirtIO-9P share, and the `fetch`-backed
/// network a browser guest can be given. Use
/// `package:dart_emu/dart_emu.dart` for the platform-independent API and
/// `package:dart_emu/dart_emu_io.dart` for native filesystem access.
library;

export 'dart_emu.dart';
export 'src/device/virtio/ninep/ninep_web_picker.dart';

/// The default backend is chosen by the platform, so it is hidden here:
/// this export exists for building one deliberately, with its upstreams and
/// credentials named.
export 'src/net/backend/net_backend_web.dart' hide createDefaultNetBackend;
