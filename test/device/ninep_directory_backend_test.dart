@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_emu/src/device/virtio/ninep/ninep_directory_backend.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_fs.dart';
import 'package:test/test.dart';

const _perm = 0x1A4;

void main() {
  group('DirectoryNinePBackend symlink containment', () {
    late Directory root;
    late Directory outside;
    late NinePBackend fs;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ninep_root_');
      outside = Directory.systemTemp.createTempSync('ninep_outside_');
      File('${outside.path}/secret.txt').writeAsStringSync('TOP SECRET');
      File('${root.path}/inside.txt').writeAsStringSync('safe content');
      Directory('${root.path}/sub').createSync();
      fs = createDirectoryNinePBackend(root.path);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });

    test('reads a real file within the root', () {
      expect(utf8.decode(fs.read('/inside.txt', 0, 100)), 'safe content');
    });

    test('a final symlink escaping the root cannot be read', () {
      Link('${root.path}/escape').createSync('${outside.path}/secret.txt');
      expect(() => fs.read('/escape', 0, 100), throwsA(isA<NinePError>()));
      // Reported as a link, never followed to leak the target's content.
      expect(fs.stat('/escape')?.isSymlink, isTrue);
    });

    test('an intermediate symlink escaping the root is blocked', () {
      Link('${root.path}/escapedir').createSync(outside.path);
      expect(
        () => fs.read('/escapedir/secret.txt', 0, 100),
        throwsA(isA<NinePError>()),
      );
      expect(() => fs.readdir('/escapedir'), throwsA(isA<NinePError>()));
    });

    test('writing through an escaping symlink is rejected', () {
      Link('${root.path}/wlink').createSync('${outside.path}/secret.txt');
      expect(
        () => fs.write('/wlink', 0, utf8.encode('pwned')),
        throwsA(isA<NinePError>()),
      );
      expect(
        File('${outside.path}/secret.txt').readAsStringSync(),
        'TOP SECRET',
      );
    });

    test('creating through an escaping directory symlink is rejected', () {
      Link('${root.path}/escapedir').createSync(outside.path);
      expect(
        () => fs.create('/escapedir', 'new.txt', isDir: false, permBits: _perm),
        throwsA(isA<NinePError>()),
      );
      expect(File('${outside.path}/new.txt').existsSync(), isFalse);
    });

    test('truncating through an escaping symlink is rejected', () {
      Link('${root.path}/tlink').createSync('${outside.path}/secret.txt');
      expect(() => fs.setLength('/tlink', 0), throwsA(isA<NinePError>()));
      expect(
        File('${outside.path}/secret.txt').readAsStringSync(),
        'TOP SECRET',
      );
    });

    test('a symlink resolving inside the root still works', () {
      Link('${root.path}/goodlink').createSync('${root.path}/inside.txt');
      expect(utf8.decode(fs.read('/goodlink', 0, 100)), 'safe content');
    });

    test('normal create/write/read/readdir/remove round-trips', () {
      fs
        ..create('/', 'new.txt', isDir: false, permBits: _perm)
        ..write('/new.txt', 0, utf8.encode('hello'));
      expect(utf8.decode(fs.read('/new.txt', 0, 100)), 'hello');
      final names = fs.readdir('/').map((s) => s.name).toList();
      expect(names, containsAll(<String>['inside.txt', 'new.txt', 'sub']));
      fs.remove('/new.txt');
      expect(fs.stat('/new.txt'), isNull);
    });
  });
}
