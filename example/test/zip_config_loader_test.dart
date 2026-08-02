import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/config/zip_config_loader.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `.zip` bundle is the only way to bring a whole machine into the browser,
/// where there is no filesystem to resolve paths against. Everything the YAML
/// refers to has to come out of the archive instead.
void main() {
  group('a minimal bundle', () {
    test('carries the machine across', () {
      final config = ZipConfigLoader.load(
        _bundle('''
version: 1
machine: riscv32
memory_size: 128
bios: bbl.bin
kernel: vmlinux.bin
cmdline: "console=hvc0 root=/dev/vda rw"
'''),
      );

      expect(config.xlen, Xlen.rv32);
      expect(config.memorySizeMb, 128);
      expect(config.cmdLine, 'console=hvc0 root=/dev/vda rw');
      expect(config.biosData, _contentOf('bbl.bin'));
      expect(config.kernelData, _contentOf('vmlinux.bin'));
    });

    test('defaults the machine and memory when unstated', () {
      final config = ZipConfigLoader.load(_bundle('kernel: vmlinux.bin\n'));
      expect(config.xlen, Xlen.rv64);
      expect(config.memorySizeMb, MachineConfig.defaultMemorySizeMb);
    });

    test('a drive becomes a block device backed by archive bytes', () {
      final config = ZipConfigLoader.load(
        _bundle('kernel: vmlinux.bin\ndrive0:\n  file: rootfs.bin\n'),
      );
      expect(config.blockDevices, hasLength(1));
    });

    test('a user ethernet becomes a device', () {
      final config = ZipConfigLoader.load(
        _bundle('kernel: vmlinux.bin\neth0:\n  driver: user\n'),
      );
      expect(config.ethDevices, hasLength(1));
    });
  });

  // The YAML may sit in a subdirectory, and its paths are relative to it.
  group('paths inside the archive', () {
    test('resolve against the config\'s own directory', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'vm/config.yaml',
            utf8.encode('kernel: vmlinux.bin\n'),
          ),
        )
        ..addFile(ArchiveFile.bytes('vm/vmlinux.bin', _contentOf('vmlinux')));

      final config = ZipConfigLoader.load(_zip(archive));
      expect(config.kernelData, _contentOf('vmlinux'));
    });

    test('a file the archive does not have is named', () {
      expect(
        () => ZipConfigLoader.load(_bundle('kernel: absent.bin\n')),
        throwsA(
          isA<ZipConfigException>().having(
            (e) => e.message,
            'message',
            contains('absent.bin'),
          ),
        ),
      );
    });
  });

  // These were parsed by the file-based loader and silently dropped here,
  // because this loader carried its own shorter list of keys.
  group('keys a bundle used to lose', () {
    test('an initrd', () {
      final config = ZipConfigLoader.load(
        _bundle('kernel: vmlinux.bin\ninitrd: initrd.bin\n'),
      );
      expect(config.initrdData, _contentOf('initrd.bin'));
    });

    test('the flags that change how the machine boots', () {
      final config = ZipConfigLoader.load(
        _bundle('''
kernel: vmlinux.bin
rtc_local_time: true
use_builtin_sbi: true
accel: none
'''),
      );
      expect(config.rtcLocalTime, isTrue);
      expect(config.useBuiltinSbi, isTrue);
      expect(config.accel, 'none');
    });

    test('a share, which is served from the archive itself', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'config.yaml',
            utf8.encode(
              'kernel: vmlinux.bin\nfs0:\n  file: work\n  tag: host\n',
            ),
          ),
        )
        ..addFile(ArchiveFile.bytes('vmlinux.bin', _contentOf('vmlinux.bin')))
        ..addFile(ArchiveFile.bytes('work/notes.txt', _contentOf('notes')))
        ..addFile(ArchiveFile.bytes('work/src/main.c', _contentOf('main')));

      final config = ZipConfigLoader.load(_zip(archive));

      expect(config.sharedFolders, hasLength(1));
      final share = config.sharedFolders.single;
      expect(share.tag, 'host');
      expect(share.backend.read('/notes.txt', 0, 64), _contentOf('notes'));
      // A guest has to be able to walk into a directory before reading
      // through it, so the intermediate has to exist too.
      expect(share.backend.stat('/src')?.isDir, isTrue);
      expect(share.backend.read('/src/main.c', 0, 64), _contentOf('main'));
    });

    test('a share the archive does not contain is refused, not ignored', () {
      expect(
        () => ZipConfigLoader.load(
          _bundle('kernel: vmlinux.bin\nfs0:\n  file: absent\n'),
        ),
        throwsA(
          isA<ZipConfigException>().having(
            (e) => e.message,
            'message',
            contains('absent'),
          ),
        ),
      );
    });

    test('a share with no tag is named by its index', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'config.yaml',
            utf8.encode('kernel: vmlinux.bin\nfs0:\n  file: work\n'),
          ),
        )
        ..addFile(ArchiveFile.bytes('vmlinux.bin', _contentOf('vmlinux.bin')))
        ..addFile(ArchiveFile.bytes('work/a.txt', _contentOf('a')));

      expect(
        ZipConfigLoader.load(_zip(archive)).sharedFolders.single.tag,
        'fs0',
      );
    });
  });

  group('a bundle that cannot be read', () {
    test('with no config at all', () {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('kernel.bin', _contentOf('k')));
      expect(
        () => ZipConfigLoader.load(_zip(archive)),
        throwsA(isA<ZipConfigException>()),
      );
    });

    test('with more than one config', () {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('a.yaml', utf8.encode('kernel: k\n')))
        ..addFile(ArchiveFile.bytes('b.yaml', utf8.encode('kernel: k\n')));
      expect(
        () => ZipConfigLoader.load(_zip(archive)),
        throwsA(isA<ZipConfigException>()),
      );
    });

    test('from a future version', () {
      expect(
        () =>
            ZipConfigLoader.load(_bundle('version: 99\nkernel: vmlinux.bin\n')),
        throwsA(
          isA<ZipConfigException>().having(
            (e) => e.message,
            'message',
            contains('99'),
          ),
        ),
      );
    });

    test('for a machine that does not exist', () {
      expect(
        () => ZipConfigLoader.load(_bundle('machine: sparc\n')),
        throwsA(
          isA<ZipConfigException>().having(
            (e) => e.message,
            'message',
            contains('sparc'),
          ),
        ),
      );
    });
  });
}

/// Builds a one-directory bundle whose archive holds every file the tests
/// refer to, so a config can name any of them.
Uint8List _bundle(String yaml) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('config.yaml', utf8.encode(yaml)));
  for (final name in ['bbl.bin', 'vmlinux.bin', 'rootfs.bin', 'initrd.bin']) {
    archive.addFile(ArchiveFile.bytes(name, _contentOf(name)));
  }
  return _zip(archive);
}

Uint8List _zip(Archive archive) =>
    Uint8List.fromList(ZipEncoder().encode(archive));

/// Distinct per name, so a test can tell which entry it was handed.
Uint8List _contentOf(String name) =>
    Uint8List.fromList(utf8.encode('content of $name'));
