import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_path.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';

/// VirtIO transport 9P device (`virtio-9p`), speaking the 9P2000.u
/// protocol used by the bundled Linux guest's `v9fs` client.
///
/// The device advertises a mount [tag] in its config space; the guest
/// mounts the share with, e.g.:
///
/// ```sh
/// mount -t 9p -o trans=virtio,version=9p2000.u,msize=65536 <tag> /mnt
/// ```
///
/// Requests are serviced synchronously from the emulator step loop: each
/// available descriptor chain carries one 9P request in its read-only
/// part and reply space in its write-only part. The device owns the fid
/// table and maps fids to paths, delegating I/O to a [NinePBackend].
class Virtio9pDevice extends VirtioDevice {
  Virtio9pDevice({
    required super.memMap,
    required this.backend,
    required this.tag,
    this.maxMessageSize = _defaultMaxMessageSize,
  }) {
    _writeMountTag();
  }

  /// The filesystem served to the guest.
  final NinePBackend backend;

  /// Mount tag advertised in config space.
  final String tag;

  /// Largest 9P message this device will negotiate (`msize` ceiling).
  final int maxMessageSize;

  final Map<int, _Fid> _fids = {};
  int _msize = _defaultMaxMessageSize;
  var _dotu = true;

  @override
  int get deviceId => _Virtio9p.deviceId;

  @override
  int get vendorId => _Virtio9p.vendorId;

  @override
  int get deviceFeatures => _Virtio9p.featureMountTag;

  @override
  int onDeviceReceive(int queueIdx, int descIdx, int readSize, int writeSize) {
    if (queueIdx != _Virtio9p.requestQueue || readSize < _headerSize) {
      return 0;
    }

    final request = Uint8List(readSize);
    memcpyFromQueue(request, queueIdx, descIdx, 0, readSize);

    final reply = _dispatch(request, writeSize);
    memcpyToQueue(queueIdx, descIdx, 0, reply, reply.length);
    consumeDescriptor(queueIdx, descIdx, reply.length);
    return 0;
  }

  /// Processes a single raw 9P [request] message and returns the raw
  /// reply, bypassing the virtqueue transport.
  ///
  /// [replyCapacity] bounds the reply size the way a guest-provided
  /// descriptor chain would; it defaults to the negotiated `msize`. This
  /// is the transport-independent entry point used by tests and by
  /// embedders that frame 9P messages themselves.
  Uint8List processRequest(Uint8List request, {int? replyCapacity}) =>
      _dispatch(request, replyCapacity ?? _msize);

  Uint8List _dispatch(Uint8List request, int writeSize) {
    final reader = _MsgReader(request)..skip(_sizeField);
    final type = reader.u8();
    final tagId = reader.u16();

    try {
      return switch (type) {
        _T.version => _version(reader, tagId),
        _T.auth => _error(tagId, _Virtio9p.authNotRequired, _Errno.eacces),
        _T.attach => _attach(reader, tagId),
        _T.walk => _walk(reader, tagId),
        _T.open => _open(reader, tagId),
        _T.create => _create(reader, tagId),
        _T.read => _read(reader, tagId, writeSize),
        _T.write => _write(reader, tagId),
        _T.clunk => _clunk(reader, tagId),
        _T.remove => _remove(reader, tagId),
        _T.stat => _stat(reader, tagId),
        _T.wstat => _wstat(reader, tagId),
        _T.flush => _reply(_R.flush, tagId, _MsgWriter()),
        _ => _error(tagId, 'unsupported 9P message $type', _Errno.enosys),
      };
    } on NinePError catch (e) {
      return _error(tagId, e.message, e.errno);
    }
  }

  Uint8List _version(_MsgReader reader, int tagId) {
    final requested = reader.u32();
    final version = reader.string();
    _msize = requested < maxMessageSize ? requested : maxMessageSize;
    if (_msize < _minMessageSize) _msize = _minMessageSize;
    _dotu = version.contains('.u');
    _fids.clear();
    final negotiated = _dotu
        ? _Virtio9p.version9p2000u
        : _Virtio9p.version9p2000;
    final body = _MsgWriter()
      ..u32(_msize)
      ..string(negotiated);
    return _reply(_R.version, tagId, body);
  }

  Uint8List _attach(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    reader
      ..u32() // afid
      ..string() // uname
      ..string(); // aname
    if (_dotu) reader.u32(); // n_uname
    final stat = backend.stat(NinePPath.root) ?? _rootStat();
    _fids[fid] = _Fid(NinePPath.root);
    return _reply(_R.attach, tagId, _MsgWriter()..qid(stat));
  }

  Uint8List _walk(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final newfid = reader.u32();
    final count = reader.u16();
    final names = [for (var i = 0; i < count; i++) reader.string()];

    final base = _requireFid(fid);
    var path = base.path;
    final qids = <NinePStat>[];
    for (final name in names) {
      final next = NinePPath.join(path, name);
      final stat = backend.stat(next);
      if (stat == null) break;
      qids.add(stat);
      path = next;
    }

    if (qids.length != names.length) {
      if (qids.isEmpty && names.isNotEmpty) throw NinePError.enoent;
      final body = _MsgWriter()..u16(qids.length);
      for (final q in qids) {
        body.qid(q);
      }
      return _reply(_R.walk, tagId, body);
    }

    _fids[newfid] = _Fid(path);
    final body = _MsgWriter()..u16(qids.length);
    for (final q in qids) {
      body.qid(q);
    }
    return _reply(_R.walk, tagId, body);
  }

  Uint8List _open(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    reader.u8(); // mode
    final entry = _requireFid(fid);
    final stat = backend.stat(entry.path);
    if (stat == null) throw NinePError.enoent;
    entry.open = true;
    if (stat.isDir) {
      entry
        ..isDir = true
        ..dirStream = _encodeDirectory(entry.path);
    }
    return _reply(
      _R.open,
      tagId,
      _MsgWriter()
        ..qid(stat)
        ..u32(0),
    );
  }

  Uint8List _create(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final name = reader.string();
    final perm = reader.u32();
    reader.u8(); // mode
    if (_dotu) reader.string(); // extension
    final parent = _requireFid(fid);
    final isDir = (perm & NinePMode.dir) != 0;
    final stat = backend.create(
      parent.path,
      name,
      isDir: isDir,
      permBits: perm & _permMask,
    );
    final childPath = NinePPath.join(parent.path, name);
    parent
      ..path = childPath
      ..open = true
      ..isDir = isDir
      ..dirStream = isDir ? _encodeDirectory(childPath) : null;
    return _reply(
      _R.create,
      tagId,
      _MsgWriter()
        ..qid(stat)
        ..u32(0),
    );
  }

  Uint8List _read(_MsgReader reader, int tagId, int writeSize) {
    final fid = reader.u32();
    final offset = reader.u64();
    final count = reader.u32();
    final entry = _requireFid(fid);

    final maxData = writeSize - _readReplyHeader;
    final capped = count < maxData ? count : maxData;
    final limit = capped < 0 ? 0 : capped;

    final Uint8List data;
    if (entry.isDir) {
      final stream = entry.dirStream ?? _encodeDirectory(entry.path);
      if (offset >= stream.length) {
        data = Uint8List(0);
      } else {
        final end = (offset + limit).clamp(offset, stream.length);
        data = Uint8List.sublistView(stream, offset, end);
      }
    } else {
      data = backend.read(entry.path, offset, limit);
    }

    final body = _MsgWriter()
      ..u32(data.length)
      ..bytes(data);
    return _reply(_R.read, tagId, body);
  }

  Uint8List _write(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final offset = reader.u64();
    final count = reader.u32();
    final data = reader.take(count);
    final entry = _requireFid(fid);
    final written = backend.write(entry.path, offset, data);
    return _reply(_R.write, tagId, _MsgWriter()..u32(written));
  }

  Uint8List _clunk(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    _fids.remove(fid);
    return _reply(_R.clunk, tagId, _MsgWriter());
  }

  Uint8List _remove(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final entry = _fids.remove(fid);
    if (entry == null) throw NinePError.enoent;
    backend.remove(entry.path);
    return _reply(_R.remove, tagId, _MsgWriter());
  }

  Uint8List _stat(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final entry = _requireFid(fid);
    final stat = backend.stat(entry.path);
    if (stat == null) throw NinePError.enoent;
    final statBytes = _encodeStat(stat);
    final body = _MsgWriter()
      ..u16(statBytes.length)
      ..bytes(statBytes);
    return _reply(_R.stat, tagId, body);
  }

  Uint8List _wstat(_MsgReader reader, int tagId) {
    final fid = reader.u32();
    final entry = _requireFid(fid);
    reader
      ..u16() // outer stat[n] size
      ..u16() // inner stat size
      ..u16() // type
      ..u32() // dev
      ..skip(_qidSize)
      ..u32() // mode
      ..u32(); // atime
    final mtime = reader.u32();
    final length = reader.u64();
    reader
      ..string() // name
      ..string() // uid
      ..string() // gid
      ..string(); // muid
    if (length >= 0 && length <= _maxTruncate) {
      backend.setLength(entry.path, length);
    }
    if (mtime != _noTouch32) backend.setMtime(entry.path, mtime);
    return _reply(_R.wstat, tagId, _MsgWriter());
  }

  Uint8List _encodeDirectory(String path) {
    final entries = backend.readdir(path);
    final builder = BytesBuilder(copy: false);
    for (final entry in entries) {
      builder.add(_encodeStat(entry));
    }
    return builder.toBytes();
  }

  /// Encodes a 9P `stat` structure (including its leading `size[2]`).
  Uint8List _encodeStat(NinePStat stat) {
    final rest = _MsgWriter()
      ..u16(0) // type (kernel use)
      ..u32(0) // dev
      ..qid(stat)
      ..u32(stat.mode)
      ..u32(stat.atimeSeconds)
      ..u32(stat.mtimeSeconds)
      ..u64(stat.length)
      ..string(stat.name)
      ..string(_owner)
      ..string(_owner)
      ..string(_owner);
    if (_dotu) {
      rest
        ..string(stat.extension)
        ..u32(0) // n_uid
        ..u32(0) // n_gid
        ..u32(0); // n_muid
    }
    final restBytes = rest.toBytes();
    return (_MsgWriter()
          ..u16(restBytes.length)
          ..bytes(restBytes))
        .toBytes();
  }

  Uint8List _error(int tagId, String message, int errno) {
    final body = _MsgWriter()..string(message);
    if (_dotu) body.u32(errno);
    return _reply(_R.error, tagId, body);
  }

  Uint8List _reply(int type, int tagId, _MsgWriter body) {
    final bodyBytes = body.toBytes();
    final total = _headerSize + bodyBytes.length;
    final out = Uint8List(total);
    ByteData.sublistView(out)
      ..setUint32(0, total, Endian.little)
      ..setUint8(_sizeField, type)
      ..setUint16(_sizeField + 1, tagId, Endian.little);
    out.setRange(_headerSize, total, bodyBytes);
    return out;
  }

  _Fid _requireFid(int fid) {
    final entry = _fids[fid];
    if (entry == null) {
      throw const NinePError('unknown fid', errno: _Errno.ebadf);
    }
    return entry;
  }

  NinePStat _rootStat() => const NinePStat(
    name: '/',
    isDir: true,
    permBits: _permMask,
    length: 0,
    mtimeSeconds: 0,
    qidPath: 1,
  );

  void _writeMountTag() {
    final tagBytes = utf8.encode(tag);
    configSpace.buffer
        .asByteData(configSpace.offsetInBytes)
        .setUint16(0, tagBytes.length, Endian.little);
    configSpace.setRange(_tagOffset, _tagOffset + tagBytes.length, tagBytes);
  }

  static const _headerSize = 7; // size[4] type[1] tag[2]
  static const _sizeField = 4;
  static const _qidSize = 13;
  static const _readReplyHeader = 11; // header[7] + count[4]
  static const _tagOffset = 2; // after tag_len[2]
  static const _permMask = 0x1FF;
  static const _owner = 'root';
  static const int _defaultMaxMessageSize = 512 * 1024;
  static const _minMessageSize = 4096;
  static const _noTouch32 = 0xFFFFFFFF;

  /// Truncation ceiling; larger `length` values in `Twstat` (including the
  /// all-ones "do not change" sentinel) are treated as no-op.
  static const _maxTruncate = 0xFFFFFFFFFF;
}

class _Fid {
  _Fid(this.path);

  String path;
  bool open = false;
  bool isDir = false;
  Uint8List? dirStream;
}

/// 9P message type codes (T-messages are requests).
class _T {
  const _T._();

  static const version = 100;
  static const auth = 102;
  static const attach = 104;
  static const flush = 108;
  static const walk = 110;
  static const open = 112;
  static const create = 114;
  static const read = 116;
  static const write = 118;
  static const clunk = 120;
  static const remove = 122;
  static const stat = 124;
  static const wstat = 126;
}

/// 9P reply type codes (R-messages), one above the matching request.
class _R {
  const _R._();

  static const version = 101;
  static const error = 107;
  static const attach = 105;
  static const flush = 109;
  static const walk = 111;
  static const open = 113;
  static const create = 115;
  static const read = 117;
  static const write = 119;
  static const clunk = 121;
  static const remove = 123;
  static const stat = 125;
  static const wstat = 127;
}

class _Virtio9p {
  const _Virtio9p._();

  static const deviceId = 9;
  static const vendorId = 0xFFFF;
  static const int featureMountTag = 1 << 0;
  static const requestQueue = 0;
  static const version9p2000u = '9P2000.u';
  static const version9p2000 = '9P2000';
  static const authNotRequired = 'no authentication required';
}

class _Errno {
  const _Errno._();

  static const eacces = 13;
  static const ebadf = 9;
  static const enosys = 38;
}

/// Little-endian cursor reader over a 9P message.
class _MsgReader {
  _MsgReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _pos = 0;

  void skip(int n) => _pos += n;

  int u8() => _view.getUint8(_pos++);

  int u16() {
    final v = _view.getUint16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int u32() {
    final v = _view.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int u64() {
    final lo = u32();
    final hi = u32();
    return lo + hi * _high32;
  }

  String string() {
    final len = u16();
    final s = utf8.decode(
      Uint8List.sublistView(_bytes, _pos, _pos + len),
      allowMalformed: true,
    );
    _pos += len;
    return s;
  }

  Uint8List take(int count) {
    final available = _bytes.length - _pos;
    final n = count < available ? count : available;
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return slice;
  }

  static const _high32 = 0x100000000;
}

/// Growable little-endian writer for a 9P message body.
///
/// Uses a copying [BytesBuilder]: the fixed-width helpers below share one
/// [_scratch] buffer, so each chunk must be copied on add rather than
/// retained by reference.
class _MsgWriter {
  final BytesBuilder _builder = BytesBuilder();
  final Uint8List _scratch = Uint8List(8);
  late final ByteData _scratchView = ByteData.sublistView(_scratch);

  void u8(int v) => _builder.addByte(v & 0xFF);

  void u16(int v) {
    _scratchView.setUint16(0, v & 0xFFFF, Endian.little);
    _builder.add(Uint8List.sublistView(_scratch, 0, 2));
  }

  void u32(int v) {
    _scratchView.setUint32(0, v & 0xFFFFFFFF, Endian.little);
    _builder.add(Uint8List.sublistView(_scratch, 0, 4));
  }

  void u64(int v) {
    final value = v < 0 ? 0 : v;
    _scratchView
      ..setUint32(0, value % _high32, Endian.little)
      ..setUint32(4, (value ~/ _high32) & 0xFFFFFFFF, Endian.little);
    _builder.add(Uint8List.sublistView(_scratch, 0, 8));
  }

  void qid(NinePStat stat) {
    u8(stat.qidType);
    u32(stat.qidVersion);
    u64(stat.qidPath);
  }

  void string(String s) {
    final bytes = utf8.encode(s);
    u16(bytes.length);
    _builder.add(bytes);
  }

  void bytes(Uint8List b) => _builder.add(b);

  Uint8List toBytes() => _builder.toBytes();

  static const _high32 = 0x100000000;
}
