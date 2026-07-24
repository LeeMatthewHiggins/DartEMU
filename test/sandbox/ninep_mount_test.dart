@Tags(['sandbox'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu_io.dart';
import 'package:test/test.dart';

/// End-to-end tests that boot a real guest and mount a VirtIO-9P share
/// backed by a host directory, exercising the full 9P2000.u path through
/// the guest's `v9fs` client. Tagged `sandbox`; run only when the asset
/// images are present.
void main() {
  const assets = 'example/assets';
  final hasAssets = File('$assets/bbl64.bin').existsSync();

  group(
    'AgentSandbox VirtIO-9P shared folder (rv64)',
    () {
      late Directory hostDir;
      late AgentSandbox sandbox;

      setUpAll(() async {
        hostDir = Directory.systemTemp.createTempSync('dartemu_9p_');
        File(
          '${hostDir.path}/from_host.txt',
        ).writeAsStringSync('seeded on the host\n');

        Uint8List read(String name) => File('$assets/$name').readAsBytesSync();
        sandbox = AgentSandbox(
          SandboxConfig(
            biosData: read('bbl64.bin'),
            kernelData: read('kernel-riscv64.bin'),
            rootfsData: read('root-riscv64.bin'),
            bootTimeout: const Duration(seconds: 120),
            defaultTimeout: const Duration(seconds: 60),
            sharedFolder: NinePShare(
              tag: 'sandbox',
              backend: createDirectoryNinePBackend(hostDir.path),
            ),
          ),
        );
        await sandbox.boot();
      });

      tearDownAll(() async {
        await sandbox.dispose();
        if (hostDir.existsSync()) hostDir.deleteSync(recursive: true);
      });

      test('mounts the share at boot', () async {
        final r = await sandbox.exec('mount | grep 9p');
        expect(r.stdout, contains('/mnt/shared'));
      });

      test('guest reads a host-seeded file', () async {
        final r = await sandbox.exec('cat /mnt/shared/from_host.txt');
        expect(r.exitCode, 0, reason: r.stdout);
        expect(r.stdout.trim(), 'seeded on the host');
      });

      test('host sees a file the guest writes', () async {
        final r = await sandbox.exec(
          'echo written-by-guest > /mnt/shared/from_guest.txt',
        );
        expect(r.succeeded, isTrue, reason: r.stdout);
        final hostFile = File('${hostDir.path}/from_guest.txt');
        expect(hostFile.existsSync(), isTrue);
        expect(hostFile.readAsStringSync().trim(), 'written-by-guest');
      });

      test('guest sees a file the host writes after boot (live)', () async {
        File('${hostDir.path}/late.txt').writeAsStringSync('appeared later\n');
        final r = await sandbox.exec('cat /mnt/shared/late.txt');
        expect(r.exitCode, 0, reason: r.stdout);
        expect(r.stdout.trim(), 'appeared later');
      });

      test('guest lists directory entries the host created', () async {
        Directory('${hostDir.path}/nested').createSync();
        File('${hostDir.path}/nested/one').writeAsStringSync('1');
        File('${hostDir.path}/nested/two').writeAsStringSync('2');
        final r = await sandbox.exec('ls /mnt/shared/nested');
        expect(r.stdout, contains('one'));
        expect(r.stdout, contains('two'));
      });

      test('round-trips arbitrary binary bytes through the share', () async {
        final data = Uint8List.fromList(
          List<int>.generate(2048, (i) => (i * 31 + 7) & 0xFF),
        );
        File('${hostDir.path}/blob.bin').writeAsBytesSync(data);
        final r = await sandbox.exec(
          'wc -c < /mnt/shared/blob.bin && cksum /mnt/shared/blob.bin',
        );
        expect(r.stdout, contains('2048'));
      });
    },
    skip: hasAssets ? false : 'guest images not present in $assets',
  );
}
