import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_memory_backend.dart';

/// One entry read from a browser directory tree.
///
/// Decoupled from the File System Access API so the tree-building logic
/// stays pure and testable off the web.
class WebFileEntry {
  /// A regular file at guest-absolute [path] holding [bytes].
  const WebFileEntry.file(this.path, Uint8List this.bytes)
    : isDirectory = false;

  /// A directory at guest-absolute [path].
  const WebFileEntry.directory(this.path) : isDirectory = true, bytes = null;

  /// Guest-absolute path of the entry (e.g. `/src/main.c`).
  final String path;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// File contents, or `null` for a directory.
  final Uint8List? bytes;
}

/// A directory the user chose in the browser, loaded into a 9P share.
class PickedShare {
  const PickedShare({required this.name, required this.backend});

  /// Display name of the chosen directory.
  final String name;

  /// In-memory 9P backend populated from the directory's files.
  final MemoryNinePBackend backend;
}

/// Builds an in-memory 9P share from a directory tree's [entries].
///
/// Parent directories are created implicitly, so the entries may arrive in
/// any order. The returned backend is synchronous and web-safe, suitable
/// for a `NinePShare` on any platform.
MemoryNinePBackend buildMemoryShare(Iterable<WebFileEntry> entries) {
  final backend = MemoryNinePBackend();
  for (final entry in entries) {
    if (entry.isDirectory) {
      backend.addDirectory(entry.path);
    } else {
      backend.addFile(entry.path, entry.bytes!);
    }
  }
  return backend;
}
