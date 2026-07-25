import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_web_share.dart';

/// Whether this browser actually exposes the File System Access directory
/// picker.
///
/// Compiling for the web is not enough — some browsers and embedded
/// webviews provide `dart.library.js_interop` yet lack
/// `showDirectoryPicker`. This checks for the global directly so callers
/// can hide UI that would otherwise do nothing.
bool get isDirectoryPickerSupported => globalContext.has('showDirectoryPicker');

/// Prompts the user to choose a directory via the browser's File System
/// Access API and loads its files into a 9P share. Web only.
///
/// Returns `null` if the user cancels or the API is unavailable (e.g. a
/// browser without directory-picker support).
///
/// The directory is opened read-write and its tree is read once, up front,
/// into an in-memory snapshot (the 9P device is synchronous). Guest writes,
/// creates, removes and truncations are mirrored back to the chosen folder
/// asynchronously via a [WriteBackNinePBackend]. Host-side edits made after
/// the pick are not reflected live.
Future<PickedShare?> pickDirectoryShare() async {
  final JSObject handle;
  try {
    handle = await _showDirectoryPicker(
      _PickerOptions(mode: _readWrite),
    ).toDart;
  } on Object {
    return null; // user dismissed the picker or the API is unavailable
  }
  final entries = <WebFileEntry>[];
  await _readInto(handle, NinePPath.root, entries);
  final memory = buildMemoryShare(entries);
  final sink = _FsaaWriteSink(_DirHandle(handle));
  return PickedShare(
    name: _Handle(handle).name,
    backend: WriteBackNinePBackend(memory, sink),
  );
}

Future<void> _readInto(
  JSObject dirHandle,
  String prefix,
  List<WebFileEntry> out,
) async {
  final iterator = _AsyncIterator(_DirHandle(dirHandle).values());
  while (true) {
    final result = await iterator.next().toDart;
    if (result.done.toDart) break;
    final entry = result.value! as JSObject;
    final handle = _Handle(entry);
    final childPath = NinePPath.join(prefix, handle.name);
    if (handle.kind == _directoryKind) {
      out.add(WebFileEntry.directory(childPath));
      await _readInto(entry, childPath, out);
    } else {
      final file = await _FileHandle(entry).getFile().toDart;
      final buffer = await file.arrayBuffer().toDart;
      out.add(WebFileEntry.file(childPath, buffer.toDart.asUint8List()));
    }
  }
}

/// Persists guest mutations back to the chosen directory over the File
/// System Access API.
///
/// Operations on a given path run **serially** through a per-path async
/// chain, so a later write or remove can never overtake an in-flight one:
/// writes cannot complete out of order or drop the latest content, and a
/// remove always runs after the writes queued before it. File writes are
/// debounced (the guest writes in `msize` chunks) and coalesced to the
/// latest content; a remove cancels any still-pending write for the path
/// and its descendants so a stale flush cannot recreate a deleted entry.
/// Removal is **non-recursive** — a directory the guest believes is empty
/// but that the host has since filled is left intact rather than
/// recursively deleted. All failures are swallowed; persistence is
/// best-effort and must never crash the emulator.
class _FsaaWriteSink implements NinePWriteSink {
  _FsaaWriteSink(this._root);

  final _DirHandle _root;
  final Map<String, Uint8List> _pending = {};
  final Map<String, Timer> _timers = {};
  final Map<String, Future<void>> _tail = {};

  @override
  void flushFile(String path, Uint8List bytes) {
    _pending[path] = bytes;
    _timers[path]?.cancel();
    _timers[path] = Timer(_flushDelay, () {
      _timers.remove(path);
      final data = _pending.remove(path);
      if (data != null) _enqueue(path, () => _writeFile(path, data));
    });
  }

  @override
  void createEntry(String path, {required bool isDir}) =>
      _enqueue(path, () => isDir ? _ensureDir(path) : _ensureFile(path));

  @override
  void removeEntry(String path) {
    _cancelPending(path);
    _enqueue(path, () => _removeEntry(path));
  }

  /// Appends [op] to the serial chain for [path], so operations on the same
  /// path never run concurrently.
  void _enqueue(String path, Future<void> Function() op) {
    final prev = _tail[path] ?? Future<void>.value();
    _tail[path] = prev.then((_) => op()).catchError((Object _) {});
  }

  /// Drops any still-pending write for [path] and its descendants, so a
  /// debounced flush cannot recreate an entry the guest just removed.
  void _cancelPending(String path) {
    final prefix = '$path/';
    final stale = _timers.keys
        .where((k) => k == path || k.startsWith(prefix))
        .toList();
    for (final key in stale) {
      _timers.remove(key)?.cancel();
      _pending.remove(key);
    }
  }

  Future<_DirHandle> _dirFor(List<String> segments) async {
    var dir = _root;
    for (final segment in segments) {
      dir = await dir
          .getDirectoryHandle(segment, _CreateOptions(create: true))
          .toDart;
    }
    return dir;
  }

  Future<void> _writeFile(String path, Uint8List bytes) async {
    try {
      final segments = _segments(path);
      final name = segments.removeLast();
      final dir = await _dirFor(segments);
      final file = await dir
          .getFileHandle(name, _CreateOptions(create: true))
          .toDart;
      final writable = await file.createWritable().toDart;
      await writable.write(bytes.toJS).toDart;
      await writable.close().toDart;
    } on Object {
      // Best-effort persistence.
    }
  }

  Future<void> _ensureFile(String path) async {
    try {
      final segments = _segments(path);
      final name = segments.removeLast();
      final dir = await _dirFor(segments);
      await dir.getFileHandle(name, _CreateOptions(create: true)).toDart;
    } on Object {
      // Best-effort.
    }
  }

  Future<void> _ensureDir(String path) async {
    try {
      await _dirFor(_segments(path));
    } on Object {
      // Best-effort.
    }
  }

  Future<void> _removeEntry(String path) async {
    try {
      final segments = _segments(path);
      final name = segments.removeLast();
      final dir = await _dirFor(segments);
      // Non-recursive: a directory the host has filled since the pick
      // (unseen by the guest's snapshot) is left intact rather than
      // recursively deleted.
      await dir.removeEntry(name).toDart;
    } on Object {
      // Best-effort; a non-empty host directory is left intact.
    }
  }

  List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  static const _flushDelay = Duration(milliseconds: 200);
}

const _directoryKind = 'directory';
const _readWrite = 'readwrite';

@JS('showDirectoryPicker')
external JSPromise<JSObject> _showDirectoryPicker([JSObject options]);

extension type _PickerOptions._(JSObject _) implements JSObject {
  external factory _PickerOptions({String mode});
}

extension type _CreateOptions._(JSObject _) implements JSObject {
  external factory _CreateOptions({bool create});
}

extension type _Handle(JSObject _) implements JSObject {
  external String get kind;
  external String get name;
}

extension type _DirHandle(JSObject _) implements JSObject {
  external JSObject values();
  external JSPromise<_DirHandle> getDirectoryHandle(
    String name, [
    JSObject options,
  ]);
  external JSPromise<_FileHandle> getFileHandle(
    String name, [
    JSObject options,
  ]);
  external JSPromise<JSAny?> removeEntry(String name);
}

extension type _FileHandle(JSObject _) implements JSObject {
  external JSPromise<_File> getFile();
  external JSPromise<_Writable> createWritable();
}

extension type _Writable(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny data);
  external JSPromise<JSAny?> close();
}

extension type _File(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _IterResult(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSAny? get value;
}

extension type _AsyncIterator(JSObject _) implements JSObject {
  external JSPromise<_IterResult> next();
}
