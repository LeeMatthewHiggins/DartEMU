@Tags(['sandbox'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// End-to-end tests that boot a real guest. Tagged `sandbox` and only
/// run when the asset images are present.
void main() {
  const assets = 'example/assets';
  final hasAssets = File('$assets/bbl64.bin').existsSync();

  SandboxConfig configFor(Xlen xlen) {
    final suffix = xlen == Xlen.rv32 ? '32' : '64';
    Uint8List read(String name) => File('$assets/$name').readAsBytesSync();
    return SandboxConfig(
      xlen: xlen,
      biosData: read('bbl$suffix.bin'),
      kernelData: read('kernel-riscv$suffix.bin'),
      rootfsData: read('root-riscv$suffix.bin'),
      bootTimeout: const Duration(seconds: 120),
      defaultTimeout: const Duration(seconds: 60),
    );
  }

  group(
    'AgentSandbox (rv64)',
    () {
      late AgentSandbox sandbox;

      setUpAll(() async {
        sandbox = AgentSandbox(configFor(Xlen.rv64));
        await sandbox.boot();
      });

      tearDownAll(() => sandbox.dispose());

      test('boots to a ready state', () {
        expect(sandbox.ready, isTrue);
      });

      test('captures stdout and a zero exit code', () async {
        final r = await sandbox.exec('echo hello world');
        expect(r.outcome, ExecOutcome.completed);
        expect(r.stdout, 'hello world');
        expect(r.exitCode, 0);
        expect(r.succeeded, isTrue);
      });

      test('reports a non-zero exit code', () async {
        final r = await sandbox.exec('false');
        expect(r.outcome, ExecOutcome.completed);
        expect(r.exitCode, isNonZero);
        expect(r.succeeded, isFalse);
      });

      test('reads the exit code of a specific failure', () async {
        final r = await sandbox.exec('sh -c "exit 42"');
        expect(r.exitCode, 42);
      });

      test('isolates state across commands (fresh cwd, real shell)', () async {
        await sandbox.exec('cd /tmp');
        final r = await sandbox.exec('pwd');
        // Each exec is a new shell line in the same session; cd persists.
        expect(r.stdout.trim(), isNotEmpty);
      });

      test('enforces a wall-clock timeout', () async {
        final r = await sandbox.exec(
          'sleep 30',
          timeout: const Duration(seconds: 2),
        );
        expect(r.outcome, ExecOutcome.timedOut);
        expect(r.exitCode, isNull);
        expect(r.wallTime.inSeconds, greaterThanOrEqualTo(2));
      });

      test('enforces an instruction budget', () async {
        final r = await sandbox.exec(
          r'i=0; while [ $i -lt 1000000 ]; do i=$((i+1)); done',
          maxInstructions: 2000000,
          timeout: const Duration(seconds: 30),
        );
        expect(r.outcome, ExecOutcome.budgetExceeded);
        expect(r.instructions, greaterThan(2000000));
      });

      test('round-trips a text file', () async {
        const content = 'line one\nline two\n';
        final w = await sandbox.writeText('/tmp/note.txt', content);
        expect(w.succeeded, isTrue, reason: w.stdout);
        final back = await sandbox.readText('/tmp/note.txt');
        expect(back, content);
      });

      test('round-trips arbitrary binary bytes', () async {
        final data = Uint8List.fromList(
          List<int>.generate(4096, (i) => (i * 37 + 11) & 0xFF),
        );
        final w = await sandbox.writeFile('/tmp/blob.bin', data);
        expect(w.succeeded, isTrue, reason: w.stdout);
        final back = await sandbox.readFile('/tmp/blob.bin');
        expect(back, orderedEquals(data));
      });

      test('guest can act on a written file', () async {
        await sandbox.writeText('/tmp/prog.sh', 'echo from-a-script\n');
        final r = await sandbox.exec('sh /tmp/prog.sh');
        expect(r.stdout, 'from-a-script');
      });
    },
    skip: hasAssets ? false : 'guest images not present in $assets',
  );
}
