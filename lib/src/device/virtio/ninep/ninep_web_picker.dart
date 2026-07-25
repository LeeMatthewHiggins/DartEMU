import 'dart:js_interop';

import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_web_share.dart';

/// Prompts the user to choose a directory via the browser's File System
/// Access API and loads its files into an in-memory 9P share.
///
/// Returns `null` if the user cancels or the API is unavailable (e.g. a
/// browser without directory-picker support). Web only.
///
/// Because the 9P device is synchronous, the whole tree is read once, up
/// front — later host-side edits are not reflected live. Files created or
/// modified by the guest live in the returned backend and are not written
/// back to disk.
Future<PickedShare?> pickDirectoryShare() async {
  final JSObject handle;
  try {
    handle = await _showDirectoryPicker().toDart;
  } on Object {
    return null; // user dismissed the picker or the API is unavailable
  }
  final entries = <WebFileEntry>[];
  await _readInto(handle, NinePPath.root, entries);
  return PickedShare(
    name: _Handle(handle).name,
    backend: buildMemoryShare(entries),
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

const _directoryKind = 'directory';

@JS('showDirectoryPicker')
external JSPromise<JSObject> _showDirectoryPicker();

extension type _Handle(JSObject _) implements JSObject {
  external String get kind;
  external String get name;
}

extension type _DirHandle(JSObject _) implements JSObject {
  external JSObject values();
}

extension type _FileHandle(JSObject _) implements JSObject {
  external JSPromise<_File> getFile();
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
