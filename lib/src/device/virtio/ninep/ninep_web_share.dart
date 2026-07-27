import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_memory_backend.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';

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
  const PickedShare({required this.name, required this.backend, this.refresh});

  /// Display name of the chosen directory.
  final String name;

  /// 9P backend serving the directory's files. When the directory was
  /// opened read-write this is a [WriteBackNinePBackend] that mirrors guest
  /// changes back to the folder; otherwise a read-only in-memory snapshot.
  final NinePBackend backend;

  /// Re-reads the chosen directory and merges host-side changes into the
  /// backend, or `null` when the share cannot be refreshed.
  ///
  /// The initial read is a one-shot snapshot, so files added or edited on
  /// the host afterwards are not visible until this runs. It is additive:
  /// host files are added or updated (host content wins) and guest-only
  /// entries are left untouched, so unsynced guest work is never clobbered.
  final Future<void> Function()? refresh;
}

/// Builds an in-memory 9P share from a directory tree's [entries].
///
/// Parent directories are created implicitly, so the entries may arrive in
/// any order. The returned backend is synchronous and web-safe, suitable
/// for a `NinePShare` on any platform.
MemoryNinePBackend buildMemoryShare(Iterable<WebFileEntry> entries) {
  final backend = MemoryNinePBackend();
  mergeEntries(backend, entries);
  return backend;
}

/// Merges a re-read directory tree's [entries] into an existing [backend].
///
/// Additive and host-wins: each entry is created or overwritten so host
/// files and directories reflect their current contents, while entries the
/// [backend] has but the tree does not (e.g. files the guest created that
/// are not yet on the host) are left untouched. Used to refresh a mounted
/// share without discarding unsynced guest work.
void mergeEntries(MemoryNinePBackend backend, Iterable<WebFileEntry> entries) {
  for (final entry in entries) {
    if (entry.isDirectory) {
      backend.addDirectory(entry.path);
    } else {
      backend.addFile(entry.path, entry.bytes!);
    }
  }
}

/// Receives guest mutations so they can be persisted outside the in-memory
/// tree (e.g. written back to a picked host folder).
///
/// Calls are made synchronously from the 9P write path; implementations
/// should apply them asynchronously and idempotently, since a file may be
/// flushed repeatedly as the guest writes it in chunks.
abstract class NinePWriteSink {
  /// Persists the full current [bytes] of the file at guest-absolute
  /// [path].
  void flushFile(String path, Uint8List bytes);

  /// Creates the file or directory at guest-absolute [path].
  void createEntry(String path, {required bool isDir});

  /// Removes the entry at guest-absolute [path].
  void removeEntry(String path);
}

/// A [NinePBackend] that serves reads from an in-memory snapshot while
/// forwarding every mutation to a [NinePWriteSink] for write-back.
///
/// Reads, stats and directory listings are answered synchronously from the
/// in-memory tree (which the guest also mutates, so it stays consistent);
/// writes, creates, removes and truncations are mirrored to the sink so an
/// implementation can persist them to real storage.
class WriteBackNinePBackend implements NinePBackend {
  WriteBackNinePBackend(this._memory, this._sink);

  final MemoryNinePBackend _memory;
  final NinePWriteSink _sink;

  @override
  NinePStat? stat(String path) => _memory.stat(path);

  @override
  List<NinePStat> readdir(String path) => _memory.readdir(path);

  @override
  Uint8List read(String path, int offset, int count) =>
      _memory.read(path, offset, count);

  @override
  int write(String path, int offset, Uint8List data) {
    final written = _memory.write(path, offset, data);
    final bytes = _memory.bytesOf(path);
    if (bytes != null) _sink.flushFile(path, bytes);
    return written;
  }

  @override
  NinePStat create(
    String parent,
    String name, {
    required bool isDir,
    required int permBits,
  }) {
    final stat = _memory.create(
      parent,
      name,
      isDir: isDir,
      permBits: permBits,
    );
    _sink.createEntry(NinePPath.join(parent, name), isDir: isDir);
    return stat;
  }

  @override
  void remove(String path) {
    _memory.remove(path);
    _sink.removeEntry(NinePPath.normalise(path));
  }

  @override
  void setLength(String path, int length) {
    _memory.setLength(path, length);
    final bytes = _memory.bytesOf(path);
    if (bytes != null) _sink.flushFile(path, bytes);
  }

  @override
  void setMtime(String path, int mtimeSeconds) =>
      _memory.setMtime(path, mtimeSeconds);
}
