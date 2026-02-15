import 'dart:typed_data';

import 'package:dart_emu/src/machine/phys_memory_range.dart';

typedef FlushTlbWriteRangeCallback = void Function(
  Uint8List ramAddr,
  int ramSize,
);

class PhysMemoryMap {
  PhysMemoryMap({this.onFlushTlbWriteRange});

  final List<PhysMemoryRange> _ranges = [];
  final FlushTlbWriteRangeCallback? onFlushTlbWriteRange;

  List<PhysMemoryRange> get ranges => List.unmodifiable(_ranges);

  RamRange registerRam({required int addr, required int size}) {
    final data = Uint8List(size);
    final range = RamRange(addr: addr, originalSize: size, data: data);
    _ranges.add(range);
    return range;
  }

  DeviceRange registerDevice({
    required int addr,
    required int size,
    required DeviceReadFunc readFunc,
    required DeviceWriteFunc writeFunc,
  }) {
    final range = DeviceRange(
      addr: addr,
      originalSize: size,
      readFunc: readFunc,
      writeFunc: writeFunc,
    );
    _ranges.add(range);
    return range;
  }

  PhysMemoryRange? findRange(int physAddr) {
    for (final range in _ranges) {
      if (range.isEnabled &&
          physAddr >= range.addr &&
          physAddr < range.addr + range.size) {
        return range;
      }
    }
    return null;
  }

  Uint8List? getRamPointer(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return null;
    final offset = physAddr - range.addr;
    return Uint8List.view(
      range.data.buffer,
      range.data.offsetInBytes + offset,
    );
  }

  int physReadU8(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint8(physAddr - range.addr);
  }

  int physReadU16(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint16(
      physAddr - range.addr,
      Endian.little,
    );
  }

  int physReadU32(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint32(
      physAddr - range.addr,
      Endian.little,
    );
  }

  int physReadU64(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    final offset = physAddr - range.addr;
    final lo = range.byteData.getUint32(offset, Endian.little);
    final hi = range.byteData.getUint32(offset + _wordBytes, Endian.little);
    return lo | (hi << _wordBits);
  }

  void physWriteU8(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint8(physAddr - range.addr, value);
  }

  void physWriteU16(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint16(physAddr - range.addr, value, Endian.little);
  }

  void physWriteU32(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint32(
      physAddr - range.addr,
      value,
      Endian.little,
    );
  }

  void physWriteU64(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    final offset = physAddr - range.addr;
    range.byteData.setUint32(offset, value & _mask32, Endian.little);
    range.byteData.setUint32(
      offset + _wordBytes,
      (value >> _wordBits) & _mask32,
      Endian.little,
    );
  }

  static const maxRanges = 32;
  static const _wordBits = 32;
  static const _wordBytes = 4;
  static const _mask32 = 0xFFFFFFFF;
}
