import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/virtio_9p.dart' show Virtio9pDevice;

/// Backend filesystem served over VirtIO-9P to the guest.
///
/// Operations are path-based and stateless: the [Virtio9pDevice] owns the
/// fid table and maps each fid to a path, calling these primitives per
/// request. Paths are always guest-absolute and normalised (a leading
/// `/`, no `.`/`..` segments, `/` for the root).
///
/// Implementations must stay free of `dart:io` so the core compiles for
/// the web; the native directory-passthrough backend lives behind a
/// conditional import. Errors are reported by throwing [NinePError],
/// which the device turns into a 9P `Rerror` reply.
abstract class NinePBackend {
  /// Returns the metadata for [path], or `null` if it does not exist.
  NinePStat? stat(String path);

  /// Lists the immediate children of the directory at [path].
  ///
  /// Each entry's [NinePStat.name] is the child's base name. Throws
  /// [NinePError] if [path] is not a directory.
  List<NinePStat> readdir(String path);

  /// Reads up to [count] bytes from the file at [path] starting at
  /// [offset]. Returns fewer bytes at end of file.
  Uint8List read(String path, int offset, int count);

  /// Writes [data] to the file at [path] starting at [offset], extending
  /// the file if needed. Returns the number of bytes written.
  int write(String path, int offset, Uint8List data);

  /// Creates a child named [name] under the directory [parent].
  ///
  /// Creates a directory when [isDir] is set, otherwise a regular file.
  /// [permBits] holds the low Unix permission bits. Returns the new
  /// entry's metadata.
  NinePStat create(
    String parent,
    String name, {
    required bool isDir,
    required int permBits,
  });

  /// Removes the file or (empty) directory at [path].
  void remove(String path);

  /// Sets the length of the file at [path] to [length] bytes.
  void setLength(String path, int length);

  /// Sets the modification time of [path] to [mtimeSeconds], if supported.
  void setMtime(String path, int mtimeSeconds) {}
}

/// Immutable metadata for a single filesystem entry.
class NinePStat {
  const NinePStat({
    required this.name,
    required this.isDir,
    required this.permBits,
    required this.length,
    required this.mtimeSeconds,
    required this.qidPath,
    this.atimeSeconds = 0,
    this.qidVersion = 0,
    this.isSymlink = false,
    this.extension = '',
  });

  /// Base name of the entry (no path separators).
  final String name;

  /// Whether this entry is a directory.
  final bool isDir;

  /// Whether this entry is a symbolic link.
  final bool isSymlink;

  /// Low Unix permission bits (mode & 0o7777).
  final int permBits;

  /// Size in bytes (0 for directories).
  final int length;

  /// Modification time in seconds since the Unix epoch.
  final int mtimeSeconds;

  /// Access time in seconds since the Unix epoch.
  final int atimeSeconds;

  /// Stable per-path identifier used for the 9P qid `path` field.
  final int qidPath;

  /// Version counter used for the 9P qid `version` field.
  final int qidVersion;

  /// 9P2000.u extension string (symlink target or device spec).
  final String extension;

  /// The 9P qid type byte derived from this entry's kind.
  int get qidType {
    if (isDir) return NinePQidType.dir;
    if (isSymlink) return NinePQidType.symlink;
    return NinePQidType.file;
  }

  /// The full 9P `mode` field: kind bits combined with [permBits].
  int get mode {
    var m = permBits & _permMask;
    if (isDir) m |= NinePMode.dir;
    if (isSymlink) m |= NinePMode.symlink;
    return m;
  }

  static const _permMask = 0x1FF;
}

/// 9P qid `type` byte values.
class NinePQidType {
  const NinePQidType._();

  static const dir = 0x80;
  static const append = 0x40;
  static const excl = 0x20;
  static const auth = 0x08;
  static const tmp = 0x04;
  static const symlink = 0x02;
  static const file = 0x00;
}

/// 9P `mode`/`perm` high-bit kind flags (the low 9 bits are Unix perms).
class NinePMode {
  const NinePMode._();

  static const dir = 0x80000000;
  static const append = 0x40000000;
  static const excl = 0x20000000;
  static const mount = 0x10000000;
  static const auth = 0x08000000;
  static const tmp = 0x04000000;
  static const symlink = 0x02000000;
}

/// A 9P protocol error, carrying a message and a Unix errno.
///
/// The device serialises this into a 9P2000.u `Rerror` reply.
class NinePError implements Exception {
  const NinePError(this.message, {this.errno = _defaultErrno});

  /// Human-readable error string sent to the guest.
  final String message;

  /// Unix errno reported to the guest.
  final int errno;

  @override
  String toString() => 'NinePError($errno): $message';

  /// EIO — generic I/O error.
  static const _defaultErrno = 5;

  /// ENOENT — no such file or directory.
  static const enoent = NinePError('no such file or directory', errno: 2);

  /// EACCES — permission denied.
  static const eacces = NinePError('permission denied', errno: 13);

  /// EEXIST — file exists.
  static const eexist = NinePError('file exists', errno: 17);

  /// ENOTDIR — not a directory.
  static const enotdir = NinePError('not a directory', errno: 20);

  /// EISDIR — is a directory.
  static const eisdir = NinePError('is a directory', errno: 21);

  /// ENOTEMPTY — directory not empty.
  static const enotempty = NinePError('directory not empty', errno: 39);
}

/// Assigns stable, monotonically increasing qid path ids per string path.
///
/// Kept web-safe by counting rather than hashing, so ids stay within the
/// JavaScript safe-integer range.
class NinePQidAllocator {
  final Map<String, int> _ids = {};
  int _next = 1;

  /// Returns a stable id for [path], allocating one on first use.
  int idFor(String path) => _ids.putIfAbsent(path, () => _next++);

  /// Drops the id for [path] (e.g. after removal).
  void forget(String path) => _ids.remove(path);
}
