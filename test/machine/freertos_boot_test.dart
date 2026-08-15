@TestOn('vm')
@Tags(['machine'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';
import 'package:test/test.dart';

/// Collects everything the guest writes to the HTIF console.
class _CaptureConsole implements CharacterDevice {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  String get text => utf8.decode(_buffer.toBytes(), allowMalformed: true);

  @override
  void writeData(Uint8List data) => _buffer.add(data);

  @override
  Uint8List readData(int maxLength) => Uint8List(0);
}

class _BootedImage {
  _BootedImage(this.machine, this.console);

  final RiscVMachine machine;
  final _CaptureConsole console;
}

_BootedImage _boot(String biosPath) {
  final console = _CaptureConsole();
  final machine = RiscVMachine.fromConfig(
    MachineConfig(
      memorySizeMb: 32,
      biosData: File(biosPath).readAsBytesSync(),
      console: console,
    ),
  );
  return _BootedImage(machine, console);
}

/// Steps the machine until it powers itself down via HTIF.
///
/// The FreeRTOS images end with a poweroff, so a healthy run always gets
/// there; the deadline only bounds a broken image. The sensor demo waits
/// on real time — mtime follows the host clock — which is why the bound
/// is wall-clock rather than a cycle budget.
void _runToPowerOff(
  RiscVMachine machine, {
  required Duration deadline,
  void Function()? onStep,
}) {
  final stopwatch = Stopwatch()..start();
  while (!machine.cpu.state.shutDown) {
    machine.step(_cyclesPerStep);
    onStep?.call();
    if (stopwatch.elapsed > deadline) {
      fail('guest did not power down within $deadline');
    }
  }
}

const _cyclesPerStep = 500000;

void main() {
  group('FreeRTOS hello image', () {
    test('boots, runs its task and powers down', () {
      final boot = _boot('data/freertos-hello-riscv64.bin');

      _runToPowerOff(boot.machine, deadline: const Duration(seconds: 10));

      expect(
        boot.console.text,
        contains('Hello, World from FreeRTOS'),
        reason:
            'the hello task prints after the scheduler starts, so this '
            'proves boot, trap handling and a context switch all worked',
      );
    });
  });

  group('FreeRTOS sensor demo image', () {
    test('streams readings through the queue and exits cleanly', () {
      final boot = _boot('data/freertos-riscv64.bin');

      _runToPowerOff(boot.machine, deadline: const Duration(seconds: 25));

      final text = boot.console.text;
      expect(text, contains('[logger] t=100ms'));
      expect(
        text,
        contains('done: 25 samples'),
        reason:
            'every reading must cross the queue; a lost tick or a broken '
            'context switch shows up here as a short count',
      );
      expect(text, contains('powering off'));
    });
  });

  group('FreeRTOS timer wiring', () {
    test('the tick programs mtimecmp past the current mtime', () {
      final boot = _boot('data/freertos-hello-riscv64.bin');
      final machine = boot.machine;

      var sawArmedTimer = false;
      _runToPowerOff(
        machine,
        deadline: const Duration(seconds: 10),
        onStep: () {
          if (machine.clint.timecmp > machine.clint.rtcTime) {
            sawArmedTimer = true;
          }
        },
      );

      expect(
        sawArmedTimer,
        isTrue,
        reason:
            'vPortSetupTimerInterrupt writes mtimecmp as a 64-bit store; '
            'if the CLINT dropped it the scheduler would never tick',
      );
    });
  });
}
