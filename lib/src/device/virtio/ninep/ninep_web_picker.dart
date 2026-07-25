import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_web_share.dart';

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
/// System Access API. Writes are debounced per path (the guest writes files
/// in `msize` chunks) and all failures are swallowed — persistence is
/// best-effort and must never crash the emulator.
class _FsaaWriteSink implements NinePWriteSink {
  _FsaaWriteSink(this._root);

  final _DirHandle _root;
  final Map<String, Uint8List> _pending = {};
  final Map<String, Timer> _timers = {};

  @override
  void flushFile(String path, Uint8List bytes) {
    _pending[path] = bytes;
    _timers[path]?.cancel();
    _timers[path] = Timer(_flushDelay, () {
      final data = _pending.remove(path);
      _timers.remove(path);
      if (data != null) unawaited(_writeFile(path, data));
    });
  }

  @override
  void createEntry(String path, {required bool isDir}) =>
      unawaited(isDir ? _ensureDir(path) : _ensureFile(path));

  @override
  void removeEntry(String path) => unawaited(_removeEntry(path));

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
      await dir.removeEntry(name, _RemoveOptions(recursive: true)).toDart;
    } on Object {
      // Best-effort.
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

extension type _RemoveOptions._(JSObject _) implements JSObject {
  external factory _RemoveOptions({bool recursive});
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
  external JSPromise<JSAny?> removeEntry(String name, [JSObject options]);
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
