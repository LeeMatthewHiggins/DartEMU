import 'package:dart_emu/src/device/virtio/ninep/ninep_directory_backend_stub.dart'
    if (dart.library.io) 'ninep_directory_backend_native.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';

/// Creates a [NinePBackend] that passes 9P operations through to a real
/// host directory rooted at [hostPath].
///
/// Only available on native platforms; throws [UnsupportedError] on the
/// web, where an in-memory backend should be used instead.
///
/// The implementation is selected by conditional import.
NinePBackend createDirectoryNinePBackend(
  String hostPath, {
  bool readOnly = false,
}) => createDirectoryNinePBackendImpl(hostPath, readOnly: readOnly);
