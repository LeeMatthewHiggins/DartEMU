@Tags(['sandbox'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// Boots a current RV32 kernel with no firmware blob.
///
/// Unlike the RV64 image this one runs `getty`, so the end of a successful
/// boot is a login prompt rather than a shell. Reaching it proves the whole
/// chain: the kernel started, mounted its root filesystem, ran `/init` and
/// spawned a userspace process that opened the console.
///
/// Build the inputs with:
///   tool/image_builder/build_kernel.sh riscv32
///   tool/image_builder/build_buildroot.sh
void main() {
  const kernelPath = 'data/kernel/kernel-riscv32-6.12.bin';
  const rootfsPath = 'data/rootfs/alpine-riscv32-rootfs.bin';

  final missing = [
    kernelPath,
    rootfsPath,
  ].where((p) => !File(p).existsSync()).toList();

  Future<String> bootUntil(String marker, {required Duration timeout}) async {
    final config = MachineConfig(
      xlen: Xlen.rv32,
      kernelData: File(kernelPath).readAsBytesSync(),
      useBuiltinSbi: true,
      cmdLine: 'console=hvc0 earlycon=sbi root=/dev/vda rw init=/init',
      blockDevices: [
        MemoryBlockDevice.fromData(File(rootfsPath).readAsBytesSync()),
      ],
    );

    final emulator = Emulator(config);
    final output = StringBuffer();
    emulator.output.listen(
      (bytes) => output.write(utf8.decode(bytes, allowMalformed: true)),
    );
    await emulator.init();

    final stopwatch = Stopwatch()..start();
    while (!output.toString().contains(marker) && stopwatch.elapsed < timeout) {
      emulator.stepFor(_stepMicroseconds);
      await Future<void>.delayed(Duration.zero);
    }
    await emulator.dispose();
    return output.toString();
  }

  group(
    'modern RV32 kernel',
    () {
      late String log;

      setUpAll(() async {
        log = await bootUntil(
          _loginPrompt,
          timeout: const Duration(minutes: 3),
        );
      });

      test('reaches userspace', () {
        expect(
          log,
          contains(_loginPrompt),
          reason: 'boot stopped before getty opened the console',
        );
      });

      test('runs the SBI this emulator provides', () {
        expect(log, contains('SBI specification v2.0 detected'));
        expect(
          log,
          contains('SBI implementation ID=0x9'),
          reason: 'the emulator identifies as itself, not OpenSBI or BBL',
        );
      });

      test('mounted the VirtIO block device as root', () {
        expect(log, contains('VFS: Mounted root (ext2 filesystem)'));
      });

      test('found the kernel at the RV32 load offset', () {
        // An RV32 kernel loaded at the RV64 offset never reaches its first
        // instruction, so any console output at all rules that out.
        expect(log, contains('Linux version 6.'));
      });
    },
    skip: missing.isEmpty
        ? null
        : 'Missing ${missing.join(', ')}. Build with '
              'tool/image_builder/build_kernel.sh riscv32 and '
              'tool/image_builder/build_buildroot.sh',
  );
}

const _loginPrompt = 'dartemu login:';
const _stepMicroseconds = 10000;
