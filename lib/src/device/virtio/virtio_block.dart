import 'dart:typed_data';

import 'package:dart_emu/src/device/block_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';

class _VirtioBlk {
  static const deviceIdBlock = 2;
  static const vendorIdDefault = 0xFFFF;
  static const requestQueueIdx = 0;
  static const headerSize = 16;
  static const statusSize = 1;
}

class _RequestType {
  static const read = 0;
  static const write = 1;
  static const flush = 4;
}

class _Status {
  static const ok = 0;
  static const ioErr = 1;
  static const unsupported = 2;
}

class VirtioBlockDevice extends VirtioDevice {
  VirtioBlockDevice({required super.memMap, required this.blockDevice}) {
    _writeCapacity();
  }

  final BlockDevice blockDevice;

  @override
  int get deviceId => _VirtioBlk.deviceIdBlock;

  @override
  int get vendorId => _VirtioBlk.vendorIdDefault;

  @override
  int get deviceFeatures => 0;

  @override
  int onDeviceReceive(int queueIdx, int descIdx, int readSize, int writeSize) {
    if (queueIdx != _VirtioBlk.requestQueueIdx) return 0;

    final header = Uint8List(_VirtioBlk.headerSize);
    memcpyFromQueue(header, queueIdx, descIdx, 0, _VirtioBlk.headerSize);

    final view = ByteData.sublistView(header);
    final type = view.getUint32(0, Endian.little);
    final sectorLo = view.getUint32(_HeaderOffset.sectorLow, Endian.little);
    final sectorHi = view.getUint32(_HeaderOffset.sectorHigh, Endian.little);
    final sectorNum = sectorLo | (sectorHi << _wordBits);

    final status = _handleRequest(
      type: type,
      sectorNum: sectorNum,
      queueIdx: queueIdx,
      descIdx: descIdx,
      readSize: readSize,
      writeSize: writeSize,
    );

    final statusBuf = Uint8List(1)..[0] = status;
    final totalWritten = writeSize > 0 ? writeSize : _VirtioBlk.statusSize;

    memcpyToQueue(
      queueIdx,
      descIdx,
      writeSize - _VirtioBlk.statusSize,
      statusBuf,
      _VirtioBlk.statusSize,
    );

    consumeDescriptor(queueIdx, descIdx, totalWritten);
    return 0;
  }

  int _handleRequest({
    required int type,
    required int sectorNum,
    required int queueIdx,
    required int descIdx,
    required int readSize,
    required int writeSize,
  }) {
    switch (type) {
      case _RequestType.read:
        return _handleRead(
          sectorNum: sectorNum,
          queueIdx: queueIdx,
          descIdx: descIdx,
          writeSize: writeSize,
        );
      case _RequestType.write:
        return _handleWrite(
          sectorNum: sectorNum,
          queueIdx: queueIdx,
          descIdx: descIdx,
          readSize: readSize,
        );
      case _RequestType.flush:
        return _Status.ok;
      default:
        return _Status.unsupported;
    }
  }

  int _handleRead({
    required int sectorNum,
    required int queueIdx,
    required int descIdx,
    required int writeSize,
  }) {
    final dataSize = writeSize - _VirtioBlk.statusSize;
    if (dataSize <= 0) return _Status.ioErr;

    final sectorCount = dataSize ~/ BlockDevice.sectorSize;
    final buffer = Uint8List(dataSize);

    try {
      blockDevice.readSectors(sectorNum, buffer, sectorCount);
    } on Exception {
      return _Status.ioErr;
    }

    memcpyToQueue(queueIdx, descIdx, 0, buffer, dataSize);
    return _Status.ok;
  }

  int _handleWrite({
    required int sectorNum,
    required int queueIdx,
    required int descIdx,
    required int readSize,
  }) {
    final dataSize = readSize - _VirtioBlk.headerSize;
    if (dataSize <= 0) return _Status.ioErr;

    final sectorCount = dataSize ~/ BlockDevice.sectorSize;
    final buffer = Uint8List(dataSize);

    memcpyFromQueue(buffer, queueIdx, descIdx, _VirtioBlk.headerSize, dataSize);

    try {
      blockDevice.writeSectors(sectorNum, buffer, sectorCount);
    } on Exception {
      return _Status.ioErr;
    }

    return _Status.ok;
  }

  void _writeCapacity() {
    configSpace.buffer.asByteData(configSpace.offsetInBytes)
      ..setUint32(0, blockDevice.sectorCount & _mask32, Endian.little)
      ..setUint32(
        _wordBytes,
        (blockDevice.sectorCount >> _wordBits) & _mask32,
        Endian.little,
      );
  }

  static const _wordBits = 32;
  static const _wordBytes = 4;
  static const _mask32 = 0xFFFFFFFF;
}

class _HeaderOffset {
  static const sectorLow = 8;
  static const sectorHigh = 12;
}
