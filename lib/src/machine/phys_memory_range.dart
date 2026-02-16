import 'dart:typed_data';

import 'package:dart_emu/src/machine/dirty_bits.dart';

typedef DeviceReadFunc = int Function(int offset, int sizeLog2);
typedef DeviceWriteFunc = void Function(int offset, int value, int sizeLog2);

sealed class PhysMemoryRange {
  PhysMemoryRange({
    required this.addr,
    required this.originalSize,
  }) : size = originalSize;

  int addr;
  final int originalSize;
  int size;

  bool get isEnabled => size != 0;

  void disable() => size = 0;

  void enable() => size = originalSize;
}

class RamRange extends PhysMemoryRange {
  RamRange({
    required super.addr,
    required super.originalSize,
    required this.data,
    DirtyBits? dirtyBits,
  }) : dirtyBits = dirtyBits ?? DirtyBits(ramSize: originalSize);

  final Uint8List data;
  final DirtyBits dirtyBits;

  late final ByteData byteData =
      ByteData.view(data.buffer, data.offsetInBytes);
}

class DeviceRange extends PhysMemoryRange {
  DeviceRange({
    required super.addr,
    required super.originalSize,
    required this.readFunc,
    required this.writeFunc,
  });

  final DeviceReadFunc readFunc;
  final DeviceWriteFunc writeFunc;
}
