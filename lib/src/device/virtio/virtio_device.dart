import 'dart:math';
import 'dart:typed_data';

import 'package:dart_emu/src/device/irq_signal.dart';
import 'package:dart_emu/src/device/virtio/virtio_queue.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

class _MmioOffset {
  static const magicValue = 0x000;
  static const version = 0x004;
  static const deviceIdReg = 0x008;
  static const vendorIdReg = 0x00c;
  static const deviceFeatures = 0x010;
  static const deviceFeaturesSel = 0x014;
  static const queueSel = 0x030;
  static const queueNumMax = 0x034;
  static const queueNum = 0x038;
  static const queueReady = 0x044;
  static const queueNotify = 0x050;
  static const interruptStatus = 0x060;
  static const interruptAck = 0x064;
  static const status = 0x070;
  static const queueDescLow = 0x080;
  static const queueDescHigh = 0x084;
  static const queueAvailLow = 0x090;
  static const queueAvailHigh = 0x094;
  static const queueUsedLow = 0x0a0;
  static const queueUsedHigh = 0x0a4;
  static const configGeneration = 0x0fc;
  static const configBase = 0x100;
}

class _MmioConst {
  static const magicValue = 0x74726976;
  static const modernVersion = 2;
  static const virtioV1FeatureBit = 1;
  static const usedInterruptBit = 1;
  static const configInterruptBit = 2;
  static const sizeLog2Word = 2;
  static const descriptorByteSize = 16;
  static const usedRingHeaderBytes = 4;
  static const usedRingEntryBytes = 8;
  static const availRingIdxOffset = 2;
  static const availRingEntriesOffset = 4;
  static const availRingEntryBytes = 2;
  static const mask32 = 0xFFFFFFFF;
}

abstract class VirtioDevice {
  VirtioDevice({required this.memMap})
    : queues = List.generate(
        VirtioQueueConstants.maxQueues,
        (_) => QueueState(),
      ),
      configSpace = Uint8List(VirtioQueueConstants.maxConfigSpaceSize);

  final PhysMemoryMap memMap;
  IrqSignal? irq;

  int intStatus = 0;
  int status = 0;
  int deviceFeaturesSel = 0;
  int queueSel = 0;
  final List<QueueState> queues;
  final Uint8List configSpace;

  int get deviceId;
  int get vendorId;
  int get deviceFeatures;

  int onDeviceReceive(int queueIdx, int descIdx, int readSize, int writeSize);

  void onConfigWrite() {}

  void reset() {
    status = 0;
    queueSel = 0;
    deviceFeaturesSel = 0;
    intStatus = 0;
    for (final qs in queues) {
      qs
        ..ready = false
        ..num = VirtioQueueConstants.maxQueueNum
        ..descAddr = 0
        ..availAddr = 0
        ..usedAddr = 0
        ..lastAvailIdx = 0;
    }
  }

  /// Captures MMIO/queue/config state for snapshotting.
  VirtioDeviceSnapshot captureState() => VirtioDeviceSnapshot(
    intStatus: intStatus,
    status: status,
    deviceFeaturesSel: deviceFeaturesSel,
    queueSel: queueSel,
    queues: [
      for (final qs in queues)
        QueueState()
          ..ready = qs.ready
          ..num = qs.num
          ..lastAvailIdx = qs.lastAvailIdx
          ..descAddr = qs.descAddr
          ..availAddr = qs.availAddr
          ..usedAddr = qs.usedAddr,
    ],
    configSpace: Uint8List.fromList(configSpace),
  );

  /// Restores state captured by [captureState].
  void restoreState(VirtioDeviceSnapshot snapshot) {
    intStatus = snapshot.intStatus;
    status = snapshot.status;
    deviceFeaturesSel = snapshot.deviceFeaturesSel;
    queueSel = snapshot.queueSel;
    for (var i = 0; i < queues.length; i++) {
      final src = snapshot.queues[i];
      queues[i]
        ..ready = src.ready
        ..num = src.num
        ..lastAvailIdx = src.lastAvailIdx
        ..descAddr = src.descAddr
        ..availAddr = src.availAddr
        ..usedAddr = src.usedAddr;
    }
    configSpace.setAll(0, snapshot.configSpace);
  }

  int readConfig(int offset, int sizeLog2) {
    switch (sizeLog2) {
      case 0:
        if (offset < configSpace.length) {
          return configSpace[offset];
        }
      case 1:
        if (offset < configSpace.length - 1) {
          return configSpace.buffer
              .asByteData(configSpace.offsetInBytes)
              .getUint16(offset, Endian.little);
        }
      case _MmioConst.sizeLog2Word:
        if (offset < configSpace.length - 3) {
          return configSpace.buffer
              .asByteData(configSpace.offsetInBytes)
              .getUint32(offset, Endian.little);
        }
    }
    return 0;
  }

  void writeConfig(int offset, int value, int sizeLog2) {
    final bd = configSpace.buffer.asByteData(configSpace.offsetInBytes);
    switch (sizeLog2) {
      case 0:
        if (offset < configSpace.length) {
          configSpace[offset] = value;
          onConfigWrite();
        }
      case 1:
        if (offset < configSpace.length - 1) {
          bd.setUint16(offset, value, Endian.little);
          onConfigWrite();
        }
      case _MmioConst.sizeLog2Word:
        if (offset < configSpace.length - 3) {
          bd.setUint32(offset, value, Endian.little);
          onConfigWrite();
        }
    }
  }

  int readMmio(int offset, int sizeLog2) {
    if (offset >= _MmioOffset.configBase) {
      return readConfig(offset - _MmioOffset.configBase, sizeLog2);
    }

    if (sizeLog2 != _MmioConst.sizeLog2Word) return 0;

    final qs = queues[queueSel];
    switch (offset) {
      case _MmioOffset.magicValue:
        return _MmioConst.magicValue;
      case _MmioOffset.version:
        return _MmioConst.modernVersion;
      case _MmioOffset.deviceIdReg:
        return deviceId;
      case _MmioOffset.vendorIdReg:
        return vendorId;
      case _MmioOffset.deviceFeatures:
        return _readDeviceFeatures();
      case _MmioOffset.deviceFeaturesSel:
        return deviceFeaturesSel;
      case _MmioOffset.queueSel:
        return queueSel;
      case _MmioOffset.queueNumMax:
        return VirtioQueueConstants.maxQueueNum;
      case _MmioOffset.queueNum:
        return qs.num;
      case _MmioOffset.queueDescLow:
        return qs.descAddr & _MmioConst.mask32;
      case _MmioOffset.queueDescHigh:
        return (qs.descAddr >> 32) & _MmioConst.mask32;
      case _MmioOffset.queueAvailLow:
        return qs.availAddr & _MmioConst.mask32;
      case _MmioOffset.queueAvailHigh:
        return (qs.availAddr >> 32) & _MmioConst.mask32;
      case _MmioOffset.queueUsedLow:
        return qs.usedAddr & _MmioConst.mask32;
      case _MmioOffset.queueUsedHigh:
        return (qs.usedAddr >> 32) & _MmioConst.mask32;
      case _MmioOffset.queueReady:
        return qs.ready ? 1 : 0;
      case _MmioOffset.interruptStatus:
        return intStatus;
      case _MmioOffset.status:
        return status;
      case _MmioOffset.configGeneration:
        return 0;
      default:
        return 0;
    }
  }

  void writeMmio(int offset, int value, int sizeLog2) {
    if (offset >= _MmioOffset.configBase) {
      writeConfig(offset - _MmioOffset.configBase, value, sizeLog2);
      return;
    }

    if (sizeLog2 != _MmioConst.sizeLog2Word) return;

    switch (offset) {
      case _MmioOffset.deviceFeaturesSel:
        deviceFeaturesSel = value;
      case _MmioOffset.queueSel:
        if (value < VirtioQueueConstants.maxQueues) {
          queueSel = value;
        }
      case _MmioOffset.queueNum:
        if (_isPowerOfTwo(value)) {
          queues[queueSel].num = value;
        }
      case _MmioOffset.queueDescLow:
        _setLow32(queues[queueSel], _AddrField.desc, value);
      case _MmioOffset.queueDescHigh:
        _setHigh32(queues[queueSel], _AddrField.desc, value);
      case _MmioOffset.queueAvailLow:
        _setLow32(queues[queueSel], _AddrField.avail, value);
      case _MmioOffset.queueAvailHigh:
        _setHigh32(queues[queueSel], _AddrField.avail, value);
      case _MmioOffset.queueUsedLow:
        _setLow32(queues[queueSel], _AddrField.used, value);
      case _MmioOffset.queueUsedHigh:
        _setHigh32(queues[queueSel], _AddrField.used, value);
      case _MmioOffset.status:
        status = value;
        if (value == 0) {
          irq?.set(0);
          reset();
        }
      case _MmioOffset.queueReady:
        queues[queueSel].ready = (value & 1) != 0;
      case _MmioOffset.queueNotify:
        if (value < VirtioQueueConstants.maxQueues) {
          _queueNotify(value);
        }
      case _MmioOffset.interruptAck:
        intStatus &= ~value;
        if (intStatus == 0) {
          irq?.set(0);
        }
    }
  }

  void consumeDescriptor(int queueIdx, int descIdx, int length) {
    final qs = queues[queueIdx];
    final mem = memMap;
    final idxAddr = qs.usedAddr + _MmioConst.availRingIdxOffset;
    final index = mem.physReadU16(idxAddr);
    mem.physWriteU16(idxAddr, index + 1);

    final entryAddr =
        qs.usedAddr +
        _MmioConst.usedRingHeaderBytes +
        (index & (qs.num - 1)) * _MmioConst.usedRingEntryBytes;
    mem
      ..physWriteU32(entryAddr, descIdx)
      ..physWriteU32(entryAddr + 4, length);

    intStatus |= _MmioConst.usedInterruptBit;
    irq?.set(1);
  }

  void notifyConfigChange() {
    intStatus |= _MmioConst.configInterruptBit;
    irq?.set(1);
  }

  VirtioDescriptor getDescriptor(int queueIdx, int descIdx) {
    final qs = queues[queueIdx];
    final addr = qs.descAddr + descIdx * _MmioConst.descriptorByteSize;
    return VirtioDescriptor(
      addr: memMap.physReadU64(addr),
      length: memMap.physReadU32(addr + 8),
      flags: memMap.physReadU16(addr + 12),
      next: memMap.physReadU16(addr + 14),
    );
  }

  ({int readSize, int writeSize})? getDescriptorRwSize(
    int queueIdx,
    int descIdx,
  ) {
    var readSize = 0;
    var writeSize = 0;
    var desc = getDescriptor(queueIdx, descIdx);
    var currentIdx = descIdx;

    while (!desc.isWriteOnly) {
      readSize += desc.length;
      if (!desc.hasNext) {
        return (readSize: readSize, writeSize: writeSize);
      }
      currentIdx = desc.next;
      desc = getDescriptor(queueIdx, currentIdx);
    }

    while (true) {
      if (!desc.isWriteOnly) return null;
      writeSize += desc.length;
      if (!desc.hasNext) break;
      currentIdx = desc.next;
      desc = getDescriptor(queueIdx, currentIdx);
    }

    return (readSize: readSize, writeSize: writeSize);
  }

  void _queueNotify(int queueIdx) {
    final qs = queues[queueIdx];
    if (qs.manualRecv) return;

    final availIdx = memMap.physReadU16(
      qs.availAddr + _MmioConst.availRingIdxOffset,
    );
    while (qs.lastAvailIdx != availIdx) {
      final descIdx = memMap.physReadU16(
        qs.availAddr +
            _MmioConst.availRingEntriesOffset +
            (qs.lastAvailIdx & (qs.num - 1)) * _MmioConst.availRingEntryBytes,
      );
      final sizes = getDescriptorRwSize(queueIdx, descIdx);
      if (sizes != null) {
        final result = onDeviceReceive(
          queueIdx,
          descIdx,
          sizes.readSize,
          sizes.writeSize,
        );
        if (result < 0) break;
      }
      qs.lastAvailIdx++;
    }
  }

  int memcpyFromQueue(
    Uint8List buf,
    int queueIdx,
    int descIdx,
    int offset,
    int count,
  ) {
    return _memcpyToFromQueue(
      buf: buf,
      queueIdx: queueIdx,
      descIdx: descIdx,
      offset: offset,
      count: count,
      toQueue: false,
    );
  }

  int memcpyToQueue(
    int queueIdx,
    int descIdx,
    int offset,
    Uint8List buf,
    int count,
  ) {
    return _memcpyToFromQueue(
      buf: buf,
      queueIdx: queueIdx,
      descIdx: descIdx,
      offset: offset,
      count: count,
      toQueue: true,
    );
  }

  int _memcpyToFromQueue({
    required Uint8List buf,
    required int queueIdx,
    required int descIdx,
    required int offset,
    required int count,
    required bool toQueue,
  }) {
    if (count == 0) return 0;

    var currentDescIdx = descIdx;
    var desc = getDescriptor(queueIdx, currentDescIdx);
    var remaining = count;
    var bufOffset = 0;
    var descOffset = offset;

    final targetWriteFlag = toQueue;

    if (toQueue) {
      while (!desc.isWriteOnly) {
        if (!desc.hasNext) return -1;
        currentDescIdx = desc.next;
        desc = getDescriptor(queueIdx, currentDescIdx);
      }
    }

    while (descOffset >= desc.length) {
      if (desc.isWriteOnly != targetWriteFlag) return -1;
      if (!desc.hasNext) return -1;
      descOffset -= desc.length;
      currentDescIdx = desc.next;
      desc = getDescriptor(queueIdx, currentDescIdx);
    }

    while (true) {
      if (desc.isWriteOnly != targetWriteFlag) return -1;
      final chunkLen = min(remaining, desc.length - descOffset);

      if (toQueue) {
        _memcpyToRam(desc.addr + descOffset, buf, bufOffset, chunkLen);
      } else {
        _memcpyFromRam(buf, bufOffset, desc.addr + descOffset, chunkLen);
      }

      remaining -= chunkLen;
      if (remaining == 0) break;

      bufOffset += chunkLen;
      descOffset += chunkLen;
      if (descOffset == desc.length) {
        if (!desc.hasNext) return -1;
        currentDescIdx = desc.next;
        desc = getDescriptor(queueIdx, currentDescIdx);
        descOffset = 0;
      }
    }
    return 0;
  }

  void _memcpyFromRam(Uint8List buf, int bufOffset, int physAddr, int count) {
    final ptr = memMap.getRamPointer(physAddr);
    if (ptr == null) return;
    buf.setRange(bufOffset, bufOffset + count, ptr);
  }

  void _memcpyToRam(int physAddr, Uint8List buf, int bufOffset, int count) {
    final ptr = memMap.getRamPointer(physAddr);
    if (ptr == null) return;
    ptr.setRange(0, count, buf, bufOffset);
    memMap.notifyRamWritten(physAddr, count);
  }

  int _readDeviceFeatures() {
    switch (deviceFeaturesSel) {
      case 0:
        return deviceFeatures;
      case 1:
        return _MmioConst.virtioV1FeatureBit;
      default:
        return 0;
    }
  }

  static bool _isPowerOfTwo(int value) =>
      value > 0 && (value & (value - 1)) == 0;

  static void _setLow32(QueueState qs, _AddrField field, int value) {
    final current = field.read(qs);
    final updated =
        (current & ~_MmioConst.mask32) | (value & _MmioConst.mask32);
    field.write(qs, updated);
  }

  static void _setHigh32(QueueState qs, _AddrField field, int value) {
    final current = field.read(qs);
    final updated =
        (current & _MmioConst.mask32) | ((value & _MmioConst.mask32) << 32);
    field.write(qs, updated);
  }
}

enum _AddrField {
  desc,
  avail,
  used;

  int read(QueueState qs) => switch (this) {
    desc => qs.descAddr,
    avail => qs.availAddr,
    used => qs.usedAddr,
  };

  void write(QueueState qs, int value) {
    switch (this) {
      case desc:
        qs.descAddr = value;
      case avail:
        qs.availAddr = value;
      case used:
        qs.usedAddr = value;
    }
  }
}

/// Captured MMIO, queue, and config state of a [VirtioDevice].
class VirtioDeviceSnapshot {
  VirtioDeviceSnapshot({
    required this.intStatus,
    required this.status,
    required this.deviceFeaturesSel,
    required this.queueSel,
    required this.queues,
    required this.configSpace,
  });

  final int intStatus;
  final int status;
  final int deviceFeaturesSel;
  final int queueSel;
  final List<QueueState> queues;
  final Uint8List configSpace;
}
