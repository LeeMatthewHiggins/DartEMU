@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/virtio/ninep/ninep_web_share.dart';
import 'package:test/test.dart';

WebFileEntry _file(String path, String text) =>
    WebFileEntry.file(path, Uint8List.fromList(utf8.encode(text)));

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
}
