@TestOn('vm')
library;

import 'package:dart_emu/src/machine/config_loader.dart';
import 'package:test/test.dart';

void main() {
  group('use_builtin_sbi', () {
    test('a modern kernel config asks for the emulator-provided SBI', () {
      final config = ConfigLoader.loadFromString('''
version: 1
machine: riscv64
kernel: kernel/kernel-riscv64-6.12.bin
use_builtin_sbi: true
''');
      expect(config.useBuiltinSbi, isTrue);
      expect(config.biosPath, isNull, reason: 'no firmware blob is involved');
    });

    test('firmware-booted configs are unaffected', () {
      final config = ConfigLoader.loadFromString('''
version: 1
machine: riscv64
bios: bbl64.bin
kernel: kernel-riscv64.bin
''');
      expect(
        config.useBuiltinSbi,
        isFalse,
        reason: 'BBL provides its own SBI; installing ours would shadow it',
      );
    });
  });
}
