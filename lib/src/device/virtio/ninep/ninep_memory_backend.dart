import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';

/// An in-memory [NinePBackend], usable on every platform including the web.
///
/// Handy for seeding files into a browser demo and as a deterministic
/// fixture for tests. The tree is a flat map keyed by normalised
/// guest-absolute path; the root `/` always exists.
class MemoryNinePBackend implements NinePBackend {
  MemoryNinePBackend() {
    _nodes['/'] = _Node.directory(_defaultDirPerm);
  }

  final Map<String, _Node> _nodes = {};
  final NinePQidAllocator _qids = NinePQidAllocator();
  var _clock = 0;

  /// Seeds a text file at [guestPath], creating parent directories.
  void addTextFile(String guestPath, String text, {int permBits = 0x1A4}) =>
      addFile(guestPath, utf8.encode(text), permBits: permBits);

  /// Seeds a binary file at [guestPath], creating parent directories.
  void addFile(String guestPath, List<int> bytes, {int permBits = 0x1A4}) {
    final path = NinePPath.normalise(guestPath);
    _ensureParents(path);
    _nodes[path] = _Node.file(Uint8List.fromList(bytes), permBits, _tick());
  }

  /// Seeds a directory at [guestPath], creating parent directories.
  void addDirectory(String guestPath, {int permBits = _defaultDirPerm}) {
    final path = NinePPath.normalise(guestPath);
    _ensureParents(path);
    _nodes[path] = _Node.directory(permBits);
  }

  /// Returns the current bytes of the file at [guestPath], or `null`.
  Uint8List? bytesOf(String guestPath) =>
      _nodes[NinePPath.normalise(guestPath)]?.bytes;

  @override
  NinePStat? stat(String path) {
    final node = _nodes[NinePPath.normalise(path)];
    if (node == null) return null;
    return _statFor(NinePPath.normalise(path), node);
  }

  @override
  List<NinePStat> readdir(String path) {
    final dir = NinePPath.normalise(path);
    final node = _nodes[dir];
    if (node == null) throw NinePError.enoent;
    if (!node.isDir) throw NinePError.enotdir;
    final entries = <NinePStat>[];
    for (final entry in _nodes.entries) {
      if (entry.key == dir) continue;
      if (NinePPath.parentOf(entry.key) == dir) {
        entries.add(_statFor(entry.key, entry.value));
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Uint8List read(String path, int offset, int count) {
    final node = _nodes[NinePPath.normalise(path)];
    if (node == null) throw NinePError.enoent;
    if (node.isDir) throw NinePError.eisdir;
    final bytes = node.bytes!;
    if (offset >= bytes.length) return Uint8List(0);
    final end = (offset + count).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  int write(String path, int offset, Uint8List data) {
    final key = NinePPath.normalise(path);
    final node = _nodes[key];
    if (node == null) throw NinePError.enoent;
    if (node.isDir) throw NinePError.eisdir;
    final current = node.bytes!;
    final end = offset + data.length;
    if (end > current.length) {
      final grown = Uint8List(end)..setAll(0, current);
      node.bytes = grown;
    }
    node.bytes!.setAll(offset, data);
    node.mtime = _tick();
    return data.length;
  }

  @override
  NinePStat create(
    String parent,
    String name, {
    required bool isDir,
    required int permBits,
  }) {
    final parentPath = NinePPath.normalise(parent);
    final parentNode = _nodes[parentPath];
    if (parentNode == null) throw NinePError.enoent;
    if (!parentNode.isDir) throw NinePError.enotdir;
    final path = NinePPath.join(parentPath, name);
    if (_nodes.containsKey(path)) throw NinePError.eexist;
    final node = isDir
        ? _Node.directory(permBits)
        : _Node.file(Uint8List(0), permBits, _tick());
    _nodes[path] = node;
    return _statFor(path, node);
  }

  @override
  void remove(String path) {
    final key = NinePPath.normalise(path);
    final node = _nodes[key];
    if (node == null) throw NinePError.enoent;
    if (node.isDir) {
      final hasChildren = _nodes.keys.any(
        (k) => k != key && NinePPath.parentOf(k) == key,
      );
      if (hasChildren) throw NinePError.enotempty;
    }
    _nodes.remove(key);
    _qids.forget(key);
  }

  @override
  void setLength(String path, int length) {
    final node = _nodes[NinePPath.normalise(path)];
    if (node == null) throw NinePError.enoent;
    if (node.isDir) throw NinePError.eisdir;
    final current = node.bytes!;
    if (length == current.length) return;
    final resized = Uint8List(length)
      ..setRange(0, length < current.length ? length : current.length, current);
    node
      ..bytes = resized
      ..mtime = _tick();
  }

  @override
  void setMtime(String path, int mtimeSeconds) {
    final node = _nodes[NinePPath.normalise(path)];
    if (node != null) node.mtime = mtimeSeconds;
  }

  void _ensureParents(String path) {
    final parent = NinePPath.parentOf(path);
    if (parent == path) return;
    if (!_nodes.containsKey(parent)) {
      _ensureParents(parent);
      _nodes[parent] = _Node.directory(_defaultDirPerm);
    }
  }

  NinePStat _statFor(String path, _Node node) => NinePStat(
    name: NinePPath.baseName(path),
    isDir: node.isDir,
    permBits: node.permBits,
    length: node.isDir ? 0 : node.bytes!.length,
    mtimeSeconds: node.mtime,
    qidPath: _qids.idFor(path),
    qidVersion: node.mtime,
  );

  int _tick() => ++_clock;

  static const _defaultDirPerm = 0x1FF;
}

class _Node {
  _Node.file(this.bytes, this.permBits, this.mtime) : isDir = false;
  _Node.directory(this.permBits) : isDir = true, bytes = null, mtime = 0;

  final bool isDir;
  Uint8List? bytes;
  int permBits;
  int mtime;
}
