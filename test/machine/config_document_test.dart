import 'package:dart_emu/src/machine/config_document.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:test/test.dart';

/// The one reader of a machine's YAML.
///
/// Imported by path rather than through the package's umbrella library on
/// purpose: coverage here is collected from what the tests import, and the
/// umbrella reaches the whole machine, which would swamp the report.
///
/// It exists as its own thing because there are two ways to fetch what a
/// config names — files on a host, entries in a `.zip` in a browser — and
/// when each reader parsed for itself they drifted, so bundles quietly lost
/// every key only one of them knew.
void main() {
  group('what a config says', () {
    test('is read whole', () {
      final doc = ConfigDocument.parse('''
version: 1
machine: riscv32
memory_size: 128
bios: bbl.bin
kernel: vmlinux.bin
initrd: initrd.img
cmdline: "console=hvc0"
rtc_local_time: true
use_builtin_sbi: true
accel: none
''');

      expect(doc.xlen, Xlen.rv32);
      expect(doc.memorySizeMb, 128);
      expect(doc.bios, 'bbl.bin');
      expect(doc.kernel, 'vmlinux.bin');
      expect(doc.initrd, 'initrd.img');
      expect(doc.cmdLine, 'console=hvc0');
      expect(doc.rtcLocalTime, isTrue);
      expect(doc.useBuiltinSbi, isTrue);
      expect(doc.accel, 'none');
    });

    test('falls back to the machine defaults when it says little', () {
      final doc = ConfigDocument.parse('kernel: vmlinux.bin\n');
      expect(doc.xlen, Xlen.rv64);
      expect(doc.memorySizeMb, MachineConfig.defaultMemorySizeMb);
      expect(doc.rtcLocalTime, isFalse);
      expect(doc.useBuiltinSbi, isFalse);
      expect(doc.drives, isEmpty);
      expect(doc.filesystems, isEmpty);
      expect(doc.ethernets, isEmpty);
    });

    // Paths stay exactly as written: what they are relative to is the
    // resolver's business, and the two resolvers disagree about it.
    test('leaves paths alone', () {
      final doc = ConfigDocument.parse('kernel: ../images/vmlinux.bin\n');
      expect(doc.kernel, '../images/vmlinux.bin');
    });
  });

  group('the numbered entries', () {
    test('are collected in order, and stop at the first gap', () {
      final doc = ConfigDocument.parse('''
drive0:
  file: root.bin
  device: vda
drive1:
  file: data.bin
''');
      expect(doc.drives, hasLength(2));
      expect(doc.drives.first.file, 'root.bin');
      expect(doc.drives.first.device, 'vda');
      expect(doc.drives.last.device, isNull);
    });

    test('a share carries its tag and whether it may be written', () {
      final doc = ConfigDocument.parse('''
fs0:
  file: /home/me/work
  tag: host
  readonly: true
''');
      expect(doc.filesystems.single.file, '/home/me/work');
      expect(doc.filesystems.single.tag, 'host');
      expect(doc.filesystems.single.readOnly, isTrue);
    });

    test('a share defaults to writable', () {
      final doc = ConfigDocument.parse('fs0:\n  file: work\n');
      expect(doc.filesystems.single.readOnly, isFalse);
    });

    test('an interface carries its driver and name', () {
      final doc = ConfigDocument.parse(
        'eth0:\n  driver: user\n  ifname: en0\n',
      );
      expect(doc.ethernets.single.driver, 'user');
      expect(doc.ethernets.single.ifname, 'en0');
    });

    test('an entry without a file is not a device', () {
      final doc = ConfigDocument.parse('drive0:\n  device: vda\n');
      expect(doc.drives, isEmpty);
    });
  });

  group('what it refuses', () {
    test('a version it does not understand', () {
      expect(
        () => ConfigDocument.parse('version: 99\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('99'),
          ),
        ),
      );
    });

    test('a machine that does not exist', () {
      expect(
        () => ConfigDocument.parse('machine: sparc\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('something that is not a mapping at all', () {
      expect(
        () => ConfigDocument.parse('- just\n- a\n- list\n'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
