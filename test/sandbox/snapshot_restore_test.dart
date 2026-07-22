@Tags(['sandbox'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// End-to-end snapshot/restore tests. Boot once, snapshot the warm VM,
/// then verify restored clones roll back state and start instantly.
void main() {
  const assets = 'example/assets';
  final hasAssets = File('$assets/bbl64.bin').existsSync();

  SandboxConfig config() {
    Uint8List read(String name) => File('$assets/$name').readAsBytesSync();
    return SandboxConfig(
      biosData: read('bbl64.bin'),
      kernelData: read('kernel-riscv64.bin'),
      rootfsData: read('root-riscv64.bin'),
      bootTimeout: const Duration(seconds: 120),
      defaultTimeout: const Duration(seconds: 60),
    );
  }

  group(
    'snapshot / restore',
    () {
      late AgentSandbox origin;
      late MachineSnapshot snapshot;
      late Duration bootTime;

      setUpAll(() async {
        origin = AgentSandbox(config());
        final sw = Stopwatch()..start();
        await origin.boot();
        bootTime = sw.elapsed;
        // Warm up: create a marker file that a restore should NOT see.
        snapshot = origin.snapshot();
      });

      tearDownAll(() => origin.dispose());

      test('restore produces a ready sandbox with no boot', () async {
        final clone = AgentSandbox.restore(config(), snapshot);
        expect(clone.ready, isTrue);
        final r = await clone.exec('echo restored');
        expect(r.stdout, 'restored');
        expect(r.exitCode, 0);
        await clone.dispose();
      });

      test('restore is much faster than a cold boot', () async {
        final sw = Stopwatch()..start();
        final clone = AgentSandbox.restore(config(), snapshot);
        final restoreTime = sw.elapsed;
        // First command confirms the restored VM actually runs.
        await clone.exec('true');
        final speedup = (bootTime.inMicroseconds / restoreTime.inMicroseconds)
            .toStringAsFixed(1);
        // Deliberately surfaced so the speedup is visible in test output.
        // ignore: avoid_print
        print(
          'boot=${bootTime.inMilliseconds}ms '
          'restore=${restoreTime.inMilliseconds}ms (${speedup}x)',
        );
        expect(restoreTime, lessThan(bootTime));
        await clone.dispose();
      });

      test('restore rolls back filesystem changes', () async {
        // Mutate the origin after the snapshot was taken.
        await origin.writeText('/tmp/after_snap.txt', 'mutation\n');
        final onOrigin = await origin.exec('cat /tmp/after_snap.txt');
        expect(onOrigin.stdout, 'mutation');

        // A fresh restore must not see the post-snapshot mutation.
        final clone = AgentSandbox.restore(config(), snapshot);
        final onClone = await clone.exec(
          'cat /tmp/after_snap.txt 2>/dev/null; echo DONE',
        );
        expect(onClone.stdout.trim(), 'DONE');
        await clone.dispose();
      });

      test('clones are independent of each other', () async {
        final a = AgentSandbox.restore(config(), snapshot);
        final b = AgentSandbox.restore(config(), snapshot);

        await a.writeText('/tmp/who.txt', 'i-am-a\n');
        await b.writeText('/tmp/who.txt', 'i-am-b\n');

        final ra = await a.exec('cat /tmp/who.txt');
        final rb = await b.exec('cat /tmp/who.txt');
        expect(ra.stdout, 'i-am-a');
        expect(rb.stdout, 'i-am-b');

        await a.dispose();
        await b.dispose();
      });

      test('restored guest keeps a coherent clock', () async {
        // sleep relies on timer interrupts surviving the restore.
        final clone = AgentSandbox.restore(config(), snapshot);
        final r = await clone.exec(
          'sleep 1; echo slept',
          timeout: const Duration(seconds: 20),
        );
        expect(r.outcome, ExecOutcome.completed);
        expect(r.stdout, 'slept');
        await clone.dispose();
      });

      test('snapshot reports a plausible size', () {
        // RAM (128 MiB) dominates; sanity-check it is in the right range.
        expect(snapshot.sizeBytes, greaterThan(64 * 1024 * 1024));
        expect(snapshot.xlen, Xlen.rv64);
      });
    },
    skip: hasAssets ? false : 'guest images not present in $assets',
  );
}
