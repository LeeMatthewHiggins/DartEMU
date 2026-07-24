import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

class _ConsoleConst {
  static const deviceIdConsole = 3;
  static const vendorIdDefault = 0xFFFF;
  static const int featureSizeBit = 1 << 0;
  static const defaultColumns = 80;
  static const defaultRows = 24;
  static const receiveQueueIdx = 0;
  static const transmitQueueIdx = 1;
  static const availRingIdxOffset = 2;
  static const availRingEntriesOffset = 4;
  static const availRingEntryBytes = 2;
}

class VirtioConsoleDevice extends VirtioDevice {
  VirtioConsoleDevice({required super.memMap, required this.characterDevice}) {
    queues[_ConsoleConst.receiveQueueIdx].manualRecv = true;
    _writeConsoleSize(_ConsoleConst.defaultColumns, _ConsoleConst.defaultRows);
  }

  final CharacterDevice characterDevice;

  @override
  int get deviceId => _ConsoleConst.deviceIdConsole;

  @override
  int get vendorId => _ConsoleConst.vendorIdDefault;

  @override
  int get deviceFeatures => _ConsoleConst.featureSizeBit;

  @override
  int onDeviceReceive(int queueIdx, int descIdx, int readSize, int writeSize) {
    if (queueIdx == _ConsoleConst.transmitQueueIdx) {
      _handleTransmit(descIdx, readSize);
    }
    return 0;
  }

  bool get canWriteData {
    final qs = queues[_ConsoleConst.receiveQueueIdx];
    if (!qs.ready) return false;
    final availIdx = memMap.physReadU16(
      qs.availAddr + _ConsoleConst.availRingIdxOffset,
    );
    return qs.lastAvailIdx != availIdx;
  }

  int get writeBufferLength {
    const queueIdx = _ConsoleConst.receiveQueueIdx;
    final qs = queues[queueIdx];
    if (!qs.ready) return 0;
    final availIdx = memMap.physReadU16(
      qs.availAddr + _ConsoleConst.availRingIdxOffset,
    );
    if (qs.lastAvailIdx == availIdx) return 0;

    final descIdx = memMap.physReadU16(
      qs.availAddr +
          _ConsoleConst.availRingEntriesOffset +
          (qs.lastAvailIdx & (qs.num - 1)) * _ConsoleConst.availRingEntryBytes,
    );

    final sizes = getDescriptorRwSize(queueIdx, descIdx);
    return sizes?.writeSize ?? 0;
  }

  int writeData(Uint8List data) {
    const queueIdx = _ConsoleConst.receiveQueueIdx;
    final qs = queues[queueIdx];
    if (!qs.ready) return 0;

    final availIdx = memMap.physReadU16(
      qs.availAddr + _ConsoleConst.availRingIdxOffset,
    );
    if (qs.lastAvailIdx == availIdx) return 0;

    final descIdx = memMap.physReadU16(
      qs.availAddr +
          _ConsoleConst.availRingEntriesOffset +
          (qs.lastAvailIdx & (qs.num - 1)) * _ConsoleConst.availRingEntryBytes,
    );

    memcpyToQueue(queueIdx, descIdx, 0, data, data.length);
    consumeDescriptor(queueIdx, descIdx, data.length);
    qs.lastAvailIdx++;
    return data.length;
  }

  void resizeEvent(int width, int height) {
    _writeConsoleSize(width, height);
    notifyConfigChange();
  }

  void _handleTransmit(int descIdx, int readSize) {
    final buf = Uint8List(readSize);
    memcpyFromQueue(buf, _ConsoleConst.transmitQueueIdx, descIdx, 0, readSize);
    characterDevice.writeData(buf);
    consumeDescriptor(_ConsoleConst.transmitQueueIdx, descIdx, 0);
  }

  void _writeConsoleSize(int columns, int rows) {
    configSpace.buffer.asByteData(configSpace.offsetInBytes)
      ..setUint16(0, columns, Endian.little)
      ..setUint16(2, rows, Endian.little);
  }
}

VirtioConsoleDevice createVirtioConsole({
  required PhysMemoryMap memMap,
  required CharacterDevice characterDevice,
}) {
  return VirtioConsoleDevice(memMap: memMap, characterDevice: characterDevice);
}
