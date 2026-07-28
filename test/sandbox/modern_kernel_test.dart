@Tags(['sandbox'])
library;

import 'dart:io';

import 'package:dart_emu/dart_emu.dart';
import 'package:test/test.dart';

/// Boots a current Linux kernel with no firmware blob, using the Supervisor
/// Binary Interface the emulator implements itself.
///
/// Build the kernel with `tool/image_builder/build_kernel.sh`.
void main() {
  const kernelPath = 'data/kernel/kernel-riscv64-6.12.bin';
  const rootfsPath = 'example/assets/root-riscv64.bin';

  final hasKernel = File(kernelPath).existsSync();
  final hasRootfs = File(rootfsPath).existsSync();

  SandboxConfig config() => SandboxConfig(
    kernelData: File(kernelPath).readAsBytesSync(),
    rootfsData: File(rootfsPath).readAsBytesSync(),
    useBuiltinSbi: true,
    memorySizeMb: 256,
    // earlycon=sbi is what carries output before VirtIO probes; a modern
    // kernel has no HTIF console driver to fall back on.
    cmdLine: 'console=hvc0 earlycon=sbi root=/dev/vda rw',
    bootTimeout: const Duration(seconds: 180),
    defaultTimeout: const Duration(seconds: 60),
  );

  group(
    'modern kernel',
    () {
      late AgentSandbox sandbox;

      setUpAll(() async {
        sandbox = AgentSandbox(config());
        await sandbox.boot();
      });

      tearDownAll(() => sandbox.dispose());

      test('reaches a shell', () async {
        final result = await sandbox.exec('echo booted');
        expect(result.stdout, 'booted');
        expect(result.exitCode, 0);
      });

      test('is a 6.x kernel, not the BBL-era one', () async {
        final release = await sandbox.exec('uname -r');
        expect(release.stdout, startsWith('6.'));
      });

      test('bound the VirtIO block device and mounted it as root', () async {
        // The kernel reports the root mount as /dev/root rather than by its
        // device name, so prove the driver bound by looking for the disk
        // itself and check the mount separately.
        final partitions = await sandbox.exec('cat /proc/partitions');
        expect(partitions.stdout, contains('vda'));

        final mounts = await sandbox.exec('cat /proc/mounts');
        expect(mounts.stdout, contains(' / ext2 rw'));
      });

      test('took timer interrupts, so the SBI TIME extension works', () async {
        // A kernel whose timer never fires cannot advance jiffies, and sleep
        // would either return instantly or hang until the test times out.
        final result = await sandbox.exec('sleep 1 && echo slept');
        expect(result.stdout, 'slept');
        expect(result.exitCode, 0);
      });
    },
    skip: hasKernel && hasRootfs
        ? null
        : 'Missing ${hasKernel ? rootfsPath : kernelPath}. '
              'Build it with tool/image_builder/build_kernel.sh',
  );
}
