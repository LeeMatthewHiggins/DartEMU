@Tags(['sandbox'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// Compiles and runs a curated subset of the TCC `tests2` suite inside
/// the guest, comparing each program's output against its `.expect`
/// file. This is an emulator correctness test: every case exercises RV64
/// code generation and the musl runtime end to end, far beyond the
/// hand-written sandbox cases. See `test/sandbox/tcc_tests2/README.md`
/// for provenance and licence.
void main() {
  const assets = 'example/assets';
  const fixtures = 'test/sandbox/tcc_tests2';
  final hasAssets = File('$assets/root-riscv64.bin').existsSync();

  final cases = Directory(fixtures).existsSync()
      ? (Directory(fixtures)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.c'))
            .map((f) => f.uri.pathSegments.last.replaceAll('.c', ''))
            .where((name) => File('$fixtures/$name.expect').existsSync())
            .toList()
          ..sort())
      : <String>[];

  group(
    'TCC tests2 conformance (rv64)',
    () {
      late AgentSandbox sandbox;

      setUpAll(() async {
        Uint8List read(String name) => File('$assets/$name').readAsBytesSync();
        sandbox = AgentSandbox(
          SandboxConfig(
            biosData: read('bbl64.bin'),
            kernelData: read('kernel-riscv64.bin'),
            rootfsData: read('root-riscv64.bin'),
            memorySizeMb: 256,
            bootTimeout: const Duration(seconds: 120),
            defaultTimeout: const Duration(seconds: 45),
          ),
        );
        await sandbox.boot();
      });

      tearDownAll(() => sandbox.dispose());

      for (final name in cases) {
        test(name, () async {
          final source = File('$fixtures/$name.c').readAsStringSync();
          final expected = File(
            '$fixtures/$name.expect',
          ).readAsStringSync().replaceAll('\r\n', '\n').trimRight();

          await sandbox.writeText('/tmp/case.c', source);
          final result = await sandbox.exec(
            'cc -o /tmp/case /tmp/case.c && /tmp/case',
          );

          expect(
            result.outcome,
            ExecOutcome.completed,
            reason: 'did not finish: ${result.stdout}',
          );
          expect(
            result.exitCode,
            0,
            reason: 'compile or run failed: ${result.stdout}',
          );
          final got = result.stdout.replaceAll('\r\n', '\n').trimRight();
          expect(got, expected);
        });
      }
    },
    skip: hasAssets ? false : 'guest images not present in $assets',
  );
}
