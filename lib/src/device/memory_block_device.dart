import 'dart:typed_data';

import 'package:dart_emu/src/device/block_device.dart';

/// A [BlockDevice] backed by an in-memory byte buffer.
class MemoryBlockDevice implements BlockDevice {
  MemoryBlockDevice(this._data);

  MemoryBlockDevice.empty(int sizeInBytes) : _data = Uint8List(sizeInBytes);

  MemoryBlockDevice.fromData(Uint8List data) : _data = Uint8List.fromList(data);

  final Uint8List _data;

  @override
  int get sectorCount => _data.length ~/ BlockDevice.sectorSize;

  @override
  void readSectors(int sectorNum, Uint8List buffer, int count) {
    final byteOffset = sectorNum * BlockDevice.sectorSize;
    final byteCount = count * BlockDevice.sectorSize;
    buffer.setRange(0, byteCount, _data, byteOffset);
  }

  @override
  void writeSectors(int sectorNum, Uint8List buffer, int count) {
    final byteOffset = sectorNum * BlockDevice.sectorSize;
    final byteCount = count * BlockDevice.sectorSize;
    _data.setRange(byteOffset, byteOffset + byteCount, buffer);
  }

  /// A copy of the full device contents, for snapshotting.
  Uint8List exportBytes() => Uint8List.fromList(_data);

  /// Restores contents captured by [exportBytes].
  void importBytes(Uint8List bytes) => _data.setAll(0, bytes);
}
