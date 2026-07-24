@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_memory_backend.dart';
import 'package:dart_emu/src/device/virtio/virtio_9p.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
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

/// Drives a [Virtio9pDevice] through its real MMIO registers and a split
/// virtqueue laid out in guest RAM, exactly as the kernel `v9fs` client
/// would: it writes a request into a readable descriptor, chains a
/// writable descriptor for the reply, rings the avail index, notifies the
/// queue, then reads the reply back from the used ring.
class _Harness {
  _Harness(NinePBackend backend) : mem = PhysMemoryMap() {
    device = Virtio9pDevice(memMap: mem, backend: backend, tag: 'test');
    mem.registerRam(addr: _ramBase, size: _ramSize);
    _configureQueue();
  }

  final PhysMemoryMap mem;
  late final Virtio9pDevice device;
  int _avail = 0;
  int _used = 0;

  void _mmio(int offset, int value) => device.writeMmio(offset, value, 2);

  void _configureQueue() {
    _mmio(_Mmio.queueSel, 0);
    _mmio(_Mmio.queueNum, _queueSize);
    _mmio(_Mmio.descLow, _descAddr & _mask32);
    _mmio(_Mmio.descHigh, _descAddr >> 32);
    _mmio(_Mmio.availLow, _availAddr & _mask32);
    _mmio(_Mmio.availHigh, _availAddr >> 32);
    _mmio(_Mmio.usedLow, _usedAddr & _mask32);
    _mmio(_Mmio.usedHigh, _usedAddr >> 32);
    _mmio(_Mmio.queueReady, 1);
  }

  void _writeDescriptor(int index, int addr, int len, int flags, int next) {
    final base = _descAddr + index * _descBytes;
    mem
      ..physWriteU64(base, addr)
      ..physWriteU32(base + 8, len)
      ..physWriteU16(base + 12, flags)
      ..physWriteU16(base + 14, next);
  }

  Uint8List send(Uint8List request) {
    mem.getRamPointer(_reqAddr)!.setRange(0, request.length, request);
    _writeDescriptor(0, _reqAddr, request.length, _descNext, 1);
    _writeDescriptor(1, _replyAddr, _replyCap, _descWrite, 0);

    mem
      ..physWriteU16(_availAddr + 4 + (_avail % _queueSize) * 2, 0)
      ..physWriteU16(_availAddr + 2, ++_avail);
    _mmio(_Mmio.queueNotify, 0);

    final entry = _usedAddr + 4 + (_used % _queueSize) * 8;
    final len = mem.physReadU32(entry + 4);
    _used++;
    return Uint8List.fromList(mem.getRamPointer(_replyAddr)!.sublist(0, len));
  }

  static const _ramBase = 0x80000000;
  static const _ramSize = 0x100000;
  static const int _descAddr = _ramBase + 0x10000;
  static const int _availAddr = _ramBase + 0x20000;
  static const int _usedAddr = _ramBase + 0x30000;
  static const int _reqAddr = _ramBase + 0x40000;
  static const int _replyAddr = _ramBase + 0x50000;
  static const _replyCap = 0x10000;
  static const _queueSize = 128;
  static const _descBytes = 16;
  static const _descNext = 1;
  static const _descWrite = 2;
  static const _mask32 = 0xFFFFFFFF;
}

/// Virtio-MMIO register offsets used to configure and notify the queue.
class _Mmio {
  static const queueSel = 0x030;
  static const queueNum = 0x038;
  static const queueReady = 0x044;
  static const queueNotify = 0x050;
  static const descLow = 0x080;
  static const descHigh = 0x084;
  static const availLow = 0x090;
  static const availHigh = 0x094;
  static const usedLow = 0x0a0;
  static const usedHigh = 0x0a4;
}

/// Minimal 9P2000.u client that frames requests and parses replies,
/// sending each request through a transport ([_Harness.send] or
/// [Virtio9pDevice.processRequest]).
class _Client {
  _Client(this.send);

  final Uint8List Function(Uint8List request) send;
  int _tag = 1;
  int _fid = 1;

  int newFid() => _fid++;

  ({int type, int tag, _Reader body}) _call(int type, _Builder body) {
    final tag = _tag++;
    final request = _frame(type, tag, body.bytes);
    final reply = send(request);
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

MemoryNinePBackend _seededFs() => MemoryNinePBackend()
  ..addTextFile('/hello.txt', 'hello 9p')
  ..addDirectory('/sub')
  ..addTextFile('/sub/a.txt', 'aaa')
  ..addTextFile('/sub/b.txt', 'bbbb');

void main() {
  group('Virtio9pDevice 9P2000.u codec', () {
    late MemoryNinePBackend fs;
    late _Client client;

    setUp(() {
      fs = _seededFs();
      // Drive through the real MMIO + virtqueue transport.
      client = _Client(_Harness(fs).send);
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

  group('Virtio9pDevice.processRequest (transport-independent)', () {
    test('round-trips a file over the raw entry point', () {
      final device = Virtio9pDevice(
        memMap: PhysMemoryMap(),
        backend: _seededFs(),
        tag: 'test',
      );
      final client = _Client(device.processRequest)
        ..version(65536, '9P2000.u')
        ..attach(_rootFid);
      final fid = client.newFid();
      expect(client.walk(_rootFid, fid, ['hello.txt']), 1);
      client.open(fid, 0);
      expect(utf8.decode(client.read(fid, 0, 100)), 'hello 9p');
    });

    test('advertises the mount tag in config space', () {
      final device = Virtio9pDevice(
        memMap: PhysMemoryMap(),
        backend: MemoryNinePBackend(),
        tag: 'share42',
      );
      // Config space begins at MMIO offset 0x100: u16 tag_len then tag.
      final tagLen = device.readMmio(0x100, 1);
      expect(tagLen, 'share42'.length);
      final bytes = [
        for (var i = 0; i < tagLen; i++) device.readMmio(0x102 + i, 0),
      ];
      expect(utf8.decode(Uint8List.fromList(bytes)), 'share42');
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
