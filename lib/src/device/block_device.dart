import 'dart:typed_data';

abstract class BlockDevice {
  int get sectorCount;
  void readSectors(int sectorNum, Uint8List buffer, int count);
  void writeSectors(int sectorNum, Uint8List buffer, int count);

  static const sectorSize = 512;
}
