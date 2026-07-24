import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';

/// Creates a directory-passthrough 9P backend rooted at [hostPath].
NinePBackend createDirectoryNinePBackendImpl(
  String hostPath, {
  bool readOnly = false,
}) => DirectoryNinePBackend(hostPath, readOnly: readOnly);

/// A [NinePBackend] that serves a real host directory to the guest.
///
/// Guest-absolute paths are normalised (so `..` cannot escape) and then
/// resolved beneath [hostRoot]. Writes are rejected when [readOnly] is
/// set. Operations use synchronous `dart:io` calls because the emulator
/// services 9P requests from its synchronous step loop.
class DirectoryNinePBackend implements NinePBackend {
  DirectoryNinePBackend(String hostRoot, {this.readOnly = false})
    : hostRoot = _stripTrailingSlash(hostRoot);

  /// Absolute host path that maps to the guest's `/`.
  final String hostRoot;

  /// Whether guest writes are rejected with `EACCES`.
  final bool readOnly;

  final NinePQidAllocator _qids = NinePQidAllocator();

  String _hostPath(String guestPath) {
    final norm = NinePPath.normalise(guestPath);
    if (norm == NinePPath.root) return hostRoot;
    return '$hostRoot$norm';
  }

  @override
  NinePStat? stat(String path) {
    final norm = NinePPath.normalise(path);
    final host = _hostPath(norm);
    final type = FileSystemEntity.typeSync(host, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    return _statFor(norm, host, type);
  }

  @override
  List<NinePStat> readdir(String path) {
    final norm = NinePPath.normalise(path);
    final host = _hostPath(norm);
    final dir = Directory(host);
    if (!dir.existsSync()) throw NinePError.enoent;
    final entries = <NinePStat>[];
    for (final entity in dir.listSync(followLinks: false)) {
      final childGuest = NinePPath.join(norm, _baseName(entity.path));
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      entries.add(_statFor(childGuest, entity.path, type));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Uint8List read(String path, int offset, int count) {
    final host = _hostPath(path);
    RandomAccessFile? raf;
    try {
      raf = File(host).openSync();
      final length = raf.lengthSync();
      if (offset >= length) return Uint8List(0);
      raf.setPositionSync(offset);
      final want = (offset + count > length) ? length - offset : count;
      return raf.readSync(want);
    } on FileSystemException catch (e) {
      throw _mapError(host, e);
    } finally {
      raf?.closeSync();
    }
  }

  @override
  int write(String path, int offset, Uint8List data) {
    _guardWritable();
    final host = _hostPath(path);
    RandomAccessFile? raf;
    try {
      raf = File(host).openSync(mode: FileMode.append)
        ..setPositionSync(offset)
        ..writeFromSync(data);
      return data.length;
    } on FileSystemException catch (e) {
      throw _mapError(host, e);
    } finally {
      raf?.closeSync();
    }
  }

  @override
  NinePStat create(
    String parent,
    String name, {
    required bool isDir,
    required int permBits,
  }) {
    _guardWritable();
    final guest = NinePPath.join(parent, name);
    final host = _hostPath(guest);
    if (FileSystemEntity.typeSync(host, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw NinePError.eexist;
    }
    try {
      if (isDir) {
        Directory(host).createSync();
      } else {
        File(host).createSync();
      }
    } on FileSystemException catch (e) {
      throw _mapError(host, e);
    }
    final type = FileSystemEntity.typeSync(host, followLinks: false);
    return _statFor(guest, host, type);
  }

  @override
  void remove(String path) {
    _guardWritable();
    final host = _hostPath(path);
    final type = FileSystemEntity.typeSync(host, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw NinePError.enoent;
    try {
      if (type == FileSystemEntityType.directory) {
        Directory(host).deleteSync();
      } else {
        File(host).deleteSync();
      }
    } on FileSystemException catch (e) {
      if (type == FileSystemEntityType.directory) throw NinePError.enotempty;
      throw _mapError(host, e);
    }
    _qids.forget(NinePPath.normalise(path));
  }

  @override
  void setLength(String path, int length) {
    _guardWritable();
    final host = _hostPath(path);
    RandomAccessFile? raf;
    try {
      raf = File(host).openSync(mode: FileMode.append)..truncateSync(length);
    } on FileSystemException catch (e) {
      throw _mapError(host, e);
    } finally {
      raf?.closeSync();
    }
  }

  @override
  void setMtime(String path, int mtimeSeconds) {
    if (readOnly) return;
    final host = _hostPath(path);
    try {
      File(host).setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(mtimeSeconds * 1000),
      );
    } on FileSystemException {
      // Best-effort; ignore platforms/entries that reject it.
    }
  }

  NinePStat _statFor(String guest, String host, FileSystemEntityType type) {
    final isDir = type == FileSystemEntityType.directory;
    final isLink = type == FileSystemEntityType.link;
    var length = 0;
    var mtime = 0;
    var perm = isDir ? _defaultDirPerm : _defaultFilePerm;
    var extension = '';
    try {
      final stat = FileStat.statSync(host);
      length = isDir ? 0 : stat.size;
      mtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
      perm = stat.mode & _permMask;
    } on FileSystemException {
      // Fall back to defaults for entries we cannot stat.
    }
    if (isLink) {
      try {
        extension = Link(host).targetSync();
      } on FileSystemException {
        extension = '';
      }
    }
    return NinePStat(
      name: NinePPath.baseName(guest),
      isDir: isDir,
      isSymlink: isLink,
      permBits: perm,
      length: length,
      mtimeSeconds: mtime,
      qidPath: _qids.idFor(guest),
      qidVersion: mtime,
      extension: extension,
    );
  }

  void _guardWritable() {
    if (readOnly) throw NinePError.eacces;
  }

  NinePError _mapError(String host, FileSystemException e) {
    if (!File(host).existsSync() && !Directory(host).existsSync()) {
      return NinePError.enoent;
    }
    return NinePError(e.message);
  }

  static String _baseName(String hostPath) {
    final stripped = _stripTrailingSlash(hostPath);
    final idx = stripped.lastIndexOf(Platform.pathSeparator);
    return idx < 0 ? stripped : stripped.substring(idx + 1);
  }

  static String _stripTrailingSlash(String path) {
    if (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  static const _permMask = 0x1FF;
  static const _defaultDirPerm = 0x1FF;
  static const _defaultFilePerm = 0x1A4;
}
