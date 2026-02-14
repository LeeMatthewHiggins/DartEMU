import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/block_device.dart';

/// A [BlockDevice] backed by a file on disk.
class FileBlockDevice implements BlockDevice {
  FileBlockDevice({
    required RandomAccessFile file,
    required this.sectorCount,
  }) : _file = file;

  factory FileBlockDevice.open(String path, {bool readOnly = false}) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('Block device file not found', path);
    }
    final mode = readOnly ? FileMode.read : FileMode.append;
    final raf = file.openSync(mode: mode);
    final length = raf.lengthSync();
    return FileBlockDevice(
      file: raf,
      sectorCount: length ~/ BlockDevice.sectorSize,
    );
  }

  final RandomAccessFile _file;

  @override
  final int sectorCount;

  @override
  void readSectors(int sectorNum, Uint8List buffer, int count) {
    final byteOffset = sectorNum * BlockDevice.sectorSize;
    final byteCount = count * BlockDevice.sectorSize;
    _file
      ..setPositionSync(byteOffset)
      ..readIntoSync(buffer, 0, byteCount);
  }

  @override
  void writeSectors(int sectorNum, Uint8List buffer, int count) {
    final byteOffset = sectorNum * BlockDevice.sectorSize;
    final byteCount = count * BlockDevice.sectorSize;
    _file
      ..setPositionSync(byteOffset)
      ..writeFromSync(buffer, 0, byteCount);
  }
}
