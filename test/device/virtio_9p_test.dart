@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// 9P message type codes exercised by the tests.
class _T {
  static const version = 100;
  static const attach = 104;
  static const walk = 110;
  static const open = 112;
  static const create = 114;
  static const read = 116;
  static const write = 118;
  static const clunk = 120;
  static const stat = 124;
}

class _R {
  static const version = 101;
  static const error = 107;
  static const attach = 105;
  static const walk = 111;
  static const open = 113;
  static const create = 115;
  static const read = 117;
  static const write = 119;
  static const clunk = 121;
  static const stat = 125;
}

const _rootFid = 0;
const _qidSize = 13;

/// Minimal 9P2000.u client that frames requests and parses replies by
/// driving [Virtio9pDevice.processRequest] directly.
class _Client {
  _Client(this.device);

  final Virtio9pDevice device;
  int _tag = 1;
  int _fid = 1;

  int newFid() => _fid++;

  ({int type, int tag, _Reader body}) _call(int type, _Builder body) {
    final tag = _tag++;
    final request = _frame(type, tag, body.bytes);
    final reply = device.processRequest(request);
    final reader = _Reader(reply)..skip(4);
    final replyType = reader.u8();
    final replyTag = reader.u16();
    expect(replyTag, tag, reason: 'reply tag echoes request tag');
    return (type: replyType, tag: replyTag, body: reader);
  }

  ({int msize, String version}) version(int msize, String v) {
    final r = _call(
      _T.version,
      _Builder()
        ..u32(msize)
        ..string(v),
    );
    expect(r.type, _R.version);
    return (msize: r.body.u32(), version: r.body.string());
  }

  void attach(int fid) {
    final r = _call(
      _T.attach,
      _Builder()
        ..u32(fid)
        ..u32(0xFFFFFFFF)
        ..string('root')
        ..string('')
        ..u32(0),
    );
    expect(r.type, _R.attach, reason: 'attach should succeed');
  }

  /// Walks from [fid] to [newfid] via [names]; returns number of qids.
  int walk(int fid, int newfid, List<String> names) {
    final b = _Builder()
      ..u32(fid)
      ..u32(newfid)
      ..u16(names.length);
    for (final n in names) {
      b.string(n);
    }
    final r = _call(_T.walk, b);
    if (r.type == _R.error) return -1;
    expect(r.type, _R.walk);
    return r.body.u16();
  }

  void open(int fid, int mode) {
    final r = _call(
      _T.open,
      _Builder()
        ..u32(fid)
        ..u8(mode),
    );
    expect(r.type, _R.open, reason: 'open should succeed');
  }

  void create(int fid, String name, int perm, int mode) {
    final r = _call(
      _T.create,
      _Builder()
        ..u32(fid)
        ..string(name)
        ..u32(perm)
        ..u8(mode)
        ..string(''),
    );
    expect(r.type, _R.create, reason: 'create should succeed');
  }

  Uint8List read(int fid, int offset, int count) {
    final r = _call(
      _T.read,
      _Builder()
        ..u32(fid)
        ..u64(offset)
        ..u32(count),
    );
    expect(r.type, _R.read);
    final n = r.body.u32();
    return r.body.take(n);
  }

  int write(int fid, int offset, List<int> data) {
    final r = _call(
      _T.write,
      _Builder()
        ..u32(fid)
        ..u64(offset)
        ..u32(data.length)
        ..raw(data),
    );
    expect(r.type, _R.write, reason: 'write should succeed');
    return r.body.u32();
  }

  void clunk(int fid) {
    final r = _call(_T.clunk, _Builder()..u32(fid));
    expect(r.type, _R.clunk);
  }

  ({String name, int length}) stat(int fid) {
    final r = _call(_T.stat, _Builder()..u32(fid));
    expect(r.type, _R.stat);
    r.body
      ..u16() // outer stat[n]
      ..u16() // inner stat size
      ..u16() // type
      ..u32() // dev
      ..skip(_qidSize)
      ..u32() // mode
      ..u32() // atime
      ..u32(); // mtime
    final length = r.body.u64();
    final name = r.body.string();
    return (name: name, length: length);
  }
}

Uint8List _frame(int type, int tag, List<int> body) {
  final total = 7 + body.length;
  final out = Uint8List(total);
  ByteData.sublistView(out)
    ..setUint32(0, total, Endian.little)
    ..setUint8(4, type)
    ..setUint16(5, tag, Endian.little);
  out.setRange(7, total, body);
  return out;
}

class _Builder {
  final List<int> _b = [];

  Uint8List get bytes => Uint8List.fromList(_b);

  void u8(int v) => _b.add(v & 0xFF);

  void u16(int v) => _b
    ..add(v & 0xFF)
    ..add((v >> 8) & 0xFF);

  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      _b.add((v >> (8 * i)) & 0xFF);
    }
  }

  void u64(int v) {
    var lo = v % 0x100000000;
    var hi = v ~/ 0x100000000;
    for (var i = 0; i < 4; i++) {
      _b.add(lo & 0xFF);
      lo >>= 8;
    }
    for (var i = 0; i < 4; i++) {
      _b.add(hi & 0xFF);
      hi >>= 8;
    }
  }

  void string(String s) {
    final bytes = utf8.encode(s);
    u16(bytes.length);
    _b.addAll(bytes);
  }

  void raw(List<int> data) => _b.addAll(data);
}

class _Reader {
  _Reader(this._bytes) : _view = ByteData.sublistView(_bytes);

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
    return lo + hi * 0x100000000;
  }

  String string() {
    final len = u16();
    final s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + len));
    _pos += len;
    return s;
  }

  Uint8List take(int n) {
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return slice;
  }
}

Virtio9pDevice _device(MemoryNinePBackend backend) =>
    Virtio9pDevice(memMap: PhysMemoryMap(), backend: backend, tag: 'test');

void main() {
  group('Virtio9pDevice 9P2000.u codec', () {
    late MemoryNinePBackend fs;
    late _Client client;

    setUp(() {
      fs = MemoryNinePBackend()
        ..addTextFile('/hello.txt', 'hello 9p')
        ..addDirectory('/sub')
        ..addTextFile('/sub/a.txt', 'aaa')
        ..addTextFile('/sub/b.txt', 'bbbb');
      client = _Client(_device(fs));
    });

    test('negotiates 9P2000.u and clamps msize', () {
      final r = client.version(1 << 20, '9P2000.u');
      expect(r.version, '9P2000.u');
      expect(r.msize, lessThanOrEqualTo(1 << 20));
      expect(r.msize, greaterThanOrEqualTo(4096));
    });

    test('attach yields a directory qid', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
    });

    test('walk + open + read returns file bytes', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      expect(client.walk(_rootFid, fid, ['hello.txt']), 1);
      client.open(fid, 0);
      final data = client.read(fid, 0, 100);
      expect(utf8.decode(data), 'hello 9p');
    });

    test('walk to a missing name returns ENOENT', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      expect(client.walk(_rootFid, fid, ['nope.txt']), -1);
    });

    test('create + write + read round-trips through the backend', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final dirFid = client.newFid();
      client
        ..walk(_rootFid, dirFid, [])
        ..create(dirFid, 'new.txt', 0x1A4, 1)
        ..write(dirFid, 0, utf8.encode('written via 9p'))
        ..clunk(dirFid);
      expect(utf8.decode(fs.bytesOf('/new.txt')!), 'written via 9p');

      final readFid = client.newFid();
      expect(client.walk(_rootFid, readFid, ['new.txt']), 1);
      client.open(readFid, 0);
      expect(utf8.decode(client.read(readFid, 0, 100)), 'written via 9p');
    });

    test('offset write splices into an existing file', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      client
        ..walk(_rootFid, fid, ['hello.txt'])
        ..open(fid, 2)
        ..write(fid, 6, utf8.encode('XY'));
      expect(utf8.decode(fs.bytesOf('/hello.txt')!), 'hello XY');
    });

    test('stat reports name and length', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      client.walk(_rootFid, fid, ['hello.txt']);
      final s = client.stat(fid);
      expect(s.name, 'hello.txt');
      expect(s.length, utf8.encode('hello 9p').length);
    });

    test('directory read enumerates children as stat entries', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      client
        ..walk(_rootFid, fid, ['sub'])
        ..open(fid, 0);
      final names = <String>[];
      var offset = 0;
      while (true) {
        final chunk = client.read(fid, offset, 8192);
        if (chunk.isEmpty) break;
        names.addAll(_parseDirNames(chunk));
        offset += chunk.length;
      }
      expect(names, containsAll(<String>['a.txt', 'b.txt']));
    });

    test('read past end of file returns empty', () {
      client
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      client
        ..walk(_rootFid, fid, ['hello.txt'])
        ..open(fid, 0);
      expect(client.read(fid, 1000, 100), isEmpty);
    });
  });
}

/// Parses concatenated 9P stat structures, returning entry names.
///
/// Each entry is `size[2]` followed by `size` bytes; within that body the
/// name string begins after the fixed fields
/// (type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8] = 39 bytes).
List<String> _parseDirNames(Uint8List data) {
  const fixedFields = 39;
  final view = ByteData.sublistView(data);
  final names = <String>[];
  var pos = 0;
  while (pos + 2 <= data.length) {
    final statSize = view.getUint16(pos, Endian.little);
    final nameOffset = pos + 2 + fixedFields;
    final nameLen = view.getUint16(nameOffset, Endian.little);
    names.add(
      utf8.decode(
        Uint8List.sublistView(data, nameOffset + 2, nameOffset + 2 + nameLen),
      ),
    );
    pos += 2 + statSize;
  }
  return names;
}
