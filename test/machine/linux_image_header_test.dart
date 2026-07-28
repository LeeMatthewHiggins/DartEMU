@TestOn('vm')
@Tags(['machine'])
library;

import 'dart:typed_data';

import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/memory_map_layout.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';
import 'package:test/test.dart';

/// Field offsets in `struct riscv_image_header`.
class _Header {
  static const size = 64;
  static const textOffset = 8;
  static const magic2 = 56;
  static const magic2Value = 0x05435352; // "RSC\x05"
}

class _Offset {
  static const rv64 = 0x200000;
  static const rv32 = 0x400000;
}

/// Builds a Linux `Image` whose header declares [textOffset], with a
/// recognisable byte at its entry point so the load address can be checked.
Uint8List _image({
  required int textOffset,
  bool withMagic = true,
  int marker = 0xAB,
}) {
  final image = Uint8List(_Header.size + 16)..[0] = marker;
  final view = ByteData.sublistView(image)
    ..setUint64(_Header.textOffset, textOffset, Endian.little);
  if (withMagic) {
    view.setUint32(_Header.magic2, _Header.magic2Value, Endian.little);
  }
  return image;
}

int _loadedAt(RiscVMachine machine, int offset) =>
    machine.memMap.physReadU8(MemoryMapLayout.ramBaseAddr + offset);

RiscVMachine _boot(Uint8List kernel, {Xlen xlen = Xlen.rv64}) =>
    RiscVMachine.fromConfig(
      MachineConfig(
        xlen: xlen,
        memorySizeMb: 64,
        kernelData: kernel,
        useBuiltinSbi: true,
      ),
    );

void main() {
  group('a kernel is loaded where its Image header asks', () {
    test('RV64 kernels land at the declared 2MB offset', () {
      final machine = _boot(_image(textOffset: _Offset.rv64));
      expect(_loadedAt(machine, _Offset.rv64), 0xAB);
    });

    test('RV32 kernels land at 4MB, not the RV64 default', () {
      // Loading an RV32 kernel at the RV64 offset produces a machine that
      // never reaches its first instruction and prints nothing at all.
      final machine = _boot(
        _image(textOffset: _Offset.rv32),
        xlen: Xlen.rv32,
      );
      expect(_loadedAt(machine, _Offset.rv32), 0xAB);
      expect(_loadedAt(machine, _Offset.rv64), 0);
    });

    test('an unusual declared offset is honoured over the default', () {
      const unusual = 0x600000;
      final machine = _boot(_image(textOffset: unusual));
      expect(_loadedAt(machine, unusual), 0xAB);
    });
  });

  group('headers that cannot be trusted fall back by architecture', () {
    test('a missing magic falls back to the RV64 default', () {
      final machine = _boot(
        _image(textOffset: _Offset.rv32, withMagic: false),
      );
      expect(_loadedAt(machine, _Offset.rv64), 0xAB);
    });

    test('a missing magic on RV32 falls back to the RV32 default', () {
      final machine = _boot(
        _image(textOffset: _Offset.rv64, withMagic: false),
        xlen: Xlen.rv32,
      );
      expect(_loadedAt(machine, _Offset.rv32), 0xAB);
    });

    test('an image too short to hold a header does not throw', () {
      final machine = _boot(Uint8List(8)..[0] = 0xAB);
      expect(_loadedAt(machine, _Offset.rv64), 0xAB);
    });

    test(
      'a zero offset is refused because RAM starts with the device tree',
      () {
        // M-mode images declare an offset of zero. Honouring it would drop the
        // kernel on top of the device tree the emulator just placed.
        final machine = _boot(_image(textOffset: 0));
        expect(_loadedAt(machine, _Offset.rv64), 0xAB);
      },
    );
  });
}
