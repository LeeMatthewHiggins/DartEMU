import 'dart:typed_data';

/// Interface for block-level storage devices (e.g. disk images).
abstract class BlockDevice {
  /// Total number of sectors available on this device.
  int get sectorCount;

  /// Reads [count] sectors starting at [sectorNum] into [buffer].
  void readSectors(int sectorNum, Uint8List buffer, int count);

  /// Writes [count] sectors from [buffer] starting at [sectorNum].
  void writeSectors(int sectorNum, Uint8List buffer, int count);

  /// Size of a single sector in bytes.
  static const sectorSize = 512;
}
