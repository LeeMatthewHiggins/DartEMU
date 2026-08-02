@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/machine/config_loader.dart';
import 'package:test/test.dart';

void main() {
  late Directory shared;

  setUp(() {
    shared = Directory.systemTemp.createTempSync('dartemu-share');
    File('${shared.path}/note.txt').writeAsStringSync('hello');
  });

  tearDown(() => shared.deleteSync(recursive: true));

  Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

  group('a share declared in YAML reaches the guest', () {
    test('fs0 becomes a mountable share', () {
      final config = ConfigResolver.resolve(
        ConfigLoader.loadFromString('''
version: 1
machine: riscv64
fs0:
  file: ${shared.path}
  tag: host
'''),
      );
      // Parsing alone was never enough: the share was dropped between the
      // config and the machine, so a configured folder never appeared.
      expect(config.sharedFolders, hasLength(1));
      expect(config.sharedFolders.single.tag, 'host');
    });

    test('the tag defaults to the share index', () {
      final config = ConfigResolver.resolve(
        ConfigLoader.loadFromString('''
version: 1
fs0:
  file: ${shared.path}
'''),
      );
      expect(config.sharedFolders.single.tag, 'fs0');
    });

    test('readonly is enforced by the server, not by the guest', () {
      final config = ConfigResolver.resolve(
        ConfigLoader.loadFromString('''
version: 1
fs0:
  file: ${shared.path}
  tag: host
  readonly: true
'''),
      );
      final backend = config.sharedFolders.single.backend;
      expect(backend.read('note.txt', 0, 5), isNotEmpty);
      // The refusal is host-side, so a root guest cannot remount past it.
      expect(
        () => backend.write('note.txt', 0, bytes('nope')),
        throwsA(anything),
      );
      expect(
        File('${shared.path}/note.txt').readAsStringSync(),
        'hello',
        reason: 'the host file must be untouched',
      );
    });

    test('a writable share accepts writes', () {
      final config = ConfigResolver.resolve(
        ConfigLoader.loadFromString('''
version: 1
fs0:
  file: ${shared.path}
  tag: host
'''),
      );
      config.sharedFolders.single.backend.write('note.txt', 0, bytes('HELLO'));
      expect(File('${shared.path}/note.txt').readAsStringSync(), 'HELLO');
    });
  });
}
