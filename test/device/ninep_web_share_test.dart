@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_memory_backend.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_web_share.dart';
import 'package:test/test.dart';

WebFileEntry _file(String path, String text) =>
    WebFileEntry.file(path, Uint8List.fromList(utf8.encode(text)));

class _RecordingSink implements NinePWriteSink {
  final List<String> events = [];

  @override
  void flushFile(String path, Uint8List bytes) =>
      events.add('flush $path ${bytes.length}');

  @override
  void createEntry(String path, {required bool isDir}) =>
      events.add('create $path dir=$isDir');

  @override
  void removeEntry(String path) => events.add('remove $path');
}

void main() {
  group('buildMemoryShare', () {
    test('builds a tree from a flat entry list', () {
      final backend = buildMemoryShare([
        const WebFileEntry.directory('/src'),
        _file('/src/main.c', 'int main(){}'),
        _file('/README.md', 'hi'),
      ]);
      expect(utf8.decode(backend.bytesOf('/src/main.c')!), 'int main(){}');
      expect(utf8.decode(backend.bytesOf('/README.md')!), 'hi');
      final names = backend.readdir('/').map((s) => s.name).toList();
      expect(names, containsAll(<String>['src', 'README.md']));
    });

    test('creates parent directories implicitly, order-independent', () {
      final backend = buildMemoryShare([
        _file('/a/b/c.txt', 'deep'),
      ]);
      expect(backend.stat('/a')?.isDir, isTrue);
      expect(backend.stat('/a/b')?.isDir, isTrue);
      expect(utf8.decode(backend.bytesOf('/a/b/c.txt')!), 'deep');
    });

    test('preserves binary content exactly', () {
      final data = Uint8List.fromList(
        List<int>.generate(512, (i) => (i * 7 + 3) & 0xFF),
      );
      final backend = buildMemoryShare([WebFileEntry.file('/blob.bin', data)]);
      expect(backend.bytesOf('/blob.bin'), orderedEquals(data));
    });

    test('an empty entry list yields just the root', () {
      final backend = buildMemoryShare(const []);
      expect(backend.readdir('/'), isEmpty);
      expect(backend.stat('/')?.isDir, isTrue);
    });
  });

  group('WriteBackNinePBackend', () {
    late MemoryNinePBackend mem;
    late _RecordingSink sink;
    late WriteBackNinePBackend fs;

    setUp(() {
      mem = MemoryNinePBackend()..addTextFile('/a.txt', 'hi');
      sink = _RecordingSink();
      fs = WriteBackNinePBackend(mem, sink);
    });

    test('reads delegate to memory without touching the sink', () {
      expect(utf8.decode(fs.read('/a.txt', 0, 100)), 'hi');
      expect(fs.stat('/a.txt')?.isDir, isFalse);
      expect(fs.readdir('/').map((s) => s.name), contains('a.txt'));
      expect(sink.events, isEmpty);
    });

    test('write updates memory and flushes the full file to the sink', () {
      fs.write('/a.txt', 0, Uint8List.fromList(utf8.encode('yo!')));
      expect(utf8.decode(mem.bytesOf('/a.txt')!), 'yo!');
      expect(sink.events, contains('flush /a.txt 3'));
    });

    test('create forwards to memory and sink', () {
      fs.create('/', 'new.txt', isDir: false, permBits: 0x1a4);
      expect(mem.stat('/new.txt'), isNotNull);
      expect(sink.events, contains('create /new.txt dir=false'));
    });

    test('mkdir forwards to memory and sink', () {
      fs.create('/', 'sub', isDir: true, permBits: 0x1ff);
      expect(mem.stat('/sub')?.isDir, isTrue);
      expect(sink.events, contains('create /sub dir=true'));
    });

    test('remove forwards to memory and sink', () {
      fs.remove('/a.txt');
      expect(mem.stat('/a.txt'), isNull);
      expect(sink.events, contains('remove /a.txt'));
    });

    test('setLength truncates memory and flushes to the sink', () {
      fs.setLength('/a.txt', 1);
      expect(utf8.decode(mem.bytesOf('/a.txt')!), 'h');
      expect(sink.events.any((e) => e.startsWith('flush /a.txt')), isTrue);
    });
  });
}
