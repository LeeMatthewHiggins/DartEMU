import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';

/// Web fallback: directory passthrough needs `dart:io`.
NinePBackend createDirectoryNinePBackendImpl(
  String hostPath, {
  bool readOnly = false,
}) => throw UnsupportedError(
  'Directory-backed 9P is unavailable on the web; use MemoryNinePBackend.',
);
