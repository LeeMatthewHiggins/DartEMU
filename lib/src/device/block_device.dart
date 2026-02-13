import 'dart:typed_data';

abstract class BlockDevice {
  int get sectorCount;
  Future<void> readSectors(int sectorNum, Uint8List buffer, int count);
  Future<void> writeSectors(int sectorNum, Uint8List buffer, int count);
}
