import 'dart:typed_data';

import 'package:dart_emu/src/machine/phys_memory_range.dart';

typedef FlushTlbWriteRangeCallback =
    void Function(Uint8List ramAddr, int ramSize);

class PhysMemoryMap {
  PhysMemoryMap({this.onFlushTlbWriteRange});

  final List<PhysMemoryRange> _ranges = [];
  final FlushTlbWriteRangeCallback? onFlushTlbWriteRange;

  List<PhysMemoryRange> get ranges => List.unmodifiable(_ranges);

  RamRange registerRam({required int addr, required int size}) {
    final data = Uint8List(size);
    final range = RamRange(addr: addr, originalSize: size, data: data);
    _insertSorted(range);
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
    _insertSorted(range);
    return range;
  }

  PhysMemoryRange? findRange(int physAddr) {
    var lo = 0;
    var hi = _ranges.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final range = _ranges[mid];
      if (physAddr < range.addr) {
        hi = mid - 1;
      } else if (physAddr >= range.addr + range.originalSize) {
        lo = mid + 1;
      } else {
        if (range.isEnabled) return range;
        return null;
      }
    }
    return null;
  }

  void _insertSorted(PhysMemoryRange range) {
    var i = 0;
    while (i < _ranges.length && _ranges[i].addr < range.addr) {
      i++;
    }
    _ranges.insert(i, range);
  }

  Uint8List? getRamPointer(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return null;
    final offset = physAddr - range.addr;
    return Uint8List.view(range.data.buffer, range.data.offsetInBytes + offset);
  }

  int physReadU8(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint8(physAddr - range.addr);
  }

  int physReadU16(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint16(physAddr - range.addr, Endian.little);
  }

  int physReadU32(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    return range.byteData.getUint32(physAddr - range.addr, Endian.little);
  }

  int physReadU64(int physAddr) {
    final range = findRange(physAddr);
    if (range is! RamRange) return 0;
    final offset = physAddr - range.addr;
    final lo = range.byteData.getUint32(offset, Endian.little);
    final hi = range.byteData.getUint32(offset + _wordBytes, Endian.little);
    return lo | (hi << _wordBits);
  }

  /// Notified after guest RAM is mutated by a non-CPU writer
  /// (device DMA, physical write helpers). Receives the physical
  /// address and length of the written region.
  void Function(int physAddr, int length)? onRamWritten;

  /// Reports an external write to guest RAM (e.g. after a DMA copy).
  void notifyRamWritten(int physAddr, int length) {
    onRamWritten?.call(physAddr, length);
  }

  void physWriteU8(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint8(physAddr - range.addr, value);
    onRamWritten?.call(physAddr, 1);
  }

  void physWriteU16(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint16(physAddr - range.addr, value, Endian.little);
    onRamWritten?.call(physAddr, 2);
  }

  void physWriteU32(int physAddr, int value) {
    final range = findRange(physAddr);
    if (range is! RamRange) return;
    range.byteData.setUint32(physAddr - range.addr, value, Endian.little);
    onRamWritten?.call(physAddr, 4);
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
    onRamWritten?.call(physAddr, 8);
  }

  static const maxRanges = 32;
  static const _wordBits = 32;
  static const _wordBytes = 4;
  static const _mask32 = 0xFFFFFFFF;
}
