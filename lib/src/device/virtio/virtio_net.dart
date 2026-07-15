import 'dart:typed_data';

import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

class _VirtioNet {
  static const deviceId = 1;
  static const vendorId = 0xFFFF;
  static const receiveQueueIdx = 0;
  static const transmitQueueIdx = 1;
  static const featureMac = 1 << 5;
  static const headerSize = 12;
  static const macLength = 6;
  static const configStatusOffset = 6;
  static const availRingIdxOffset = 2;
  static const availRingEntriesOffset = 4;
  static const availRingEntryBytes = 2;
}

/// VirtIO network device.
///
/// Queue 0 is the receive queue (host-to-guest, manual receive).
/// Queue 1 is the transmit queue (guest-to-host, auto-processed).
class VirtioNetDevice extends VirtioDevice {
  VirtioNetDevice({required super.memMap, required this.ethernetDevice}) {
    queues[_VirtioNet.receiveQueueIdx].manualRecv = true;
    configSpace.setRange(0, _VirtioNet.macLength, ethernetDevice.macAddress);
    // Link status = up.
    configSpace[_VirtioNet.configStatusOffset] = 1;
  }

  final EthernetDevice ethernetDevice;

  @override
  int get deviceId => _VirtioNet.deviceId;

  @override
  int get vendorId => _VirtioNet.vendorId;

  @override
  int get deviceFeatures => _VirtioNet.featureMac;

  @override
  int onDeviceReceive(int queueIdx, int descIdx, int readSize, int writeSize) {
    if (queueIdx == _VirtioNet.transmitQueueIdx) {
      _handleTransmit(descIdx, readSize);
    }
    return 0;
  }

  /// Whether the receive queue has available descriptors.
  bool get canReceivePacket {
    final qs = queues[_VirtioNet.receiveQueueIdx];
    if (!qs.ready) return false;
    final availIdx = memMap.physReadU16(
      qs.availAddr + _VirtioNet.availRingIdxOffset,
    );
    return qs.lastAvailIdx != availIdx;
  }

  /// Size of the next available receive buffer minus the header.
  int get receiveBufferSize {
    const queueIdx = _VirtioNet.receiveQueueIdx;
    final qs = queues[queueIdx];
    if (!qs.ready) return 0;
    final availIdx = memMap.physReadU16(
      qs.availAddr + _VirtioNet.availRingIdxOffset,
    );
    if (qs.lastAvailIdx == availIdx) return 0;

    final descIdx = memMap.physReadU16(
      qs.availAddr +
          _VirtioNet.availRingEntriesOffset +
          (qs.lastAvailIdx & (qs.num - 1)) * _VirtioNet.availRingEntryBytes,
    );
    final sizes = getDescriptorRwSize(queueIdx, descIdx);
    final writeSize = sizes?.writeSize ?? 0;
    return writeSize > _VirtioNet.headerSize
        ? writeSize - _VirtioNet.headerSize
        : 0;
  }

  /// Delivers an Ethernet frame to the guest via the receive queue.
  void receivePacket(Uint8List frame) {
    const queueIdx = _VirtioNet.receiveQueueIdx;
    final qs = queues[queueIdx];
    if (!qs.ready) return;

    final availIdx = memMap.physReadU16(
      qs.availAddr + _VirtioNet.availRingIdxOffset,
    );
    if (qs.lastAvailIdx == availIdx) return;

    final descIdx = memMap.physReadU16(
      qs.availAddr +
          _VirtioNet.availRingEntriesOffset +
          (qs.lastAvailIdx & (qs.num - 1)) * _VirtioNet.availRingEntryBytes,
    );

    final header = Uint8List(_VirtioNet.headerSize);
    memcpyToQueue(queueIdx, descIdx, 0, header, header.length);
    memcpyToQueue(
      queueIdx,
      descIdx,
      _VirtioNet.headerSize,
      frame,
      frame.length,
    );

    final totalLength = _VirtioNet.headerSize + frame.length;
    consumeDescriptor(queueIdx, descIdx, totalLength);
    qs.lastAvailIdx++;
  }

  void _handleTransmit(int descIdx, int readSize) {
    if (readSize <= _VirtioNet.headerSize) return;

    final frameSize = readSize - _VirtioNet.headerSize;
    final frame = Uint8List(frameSize);
    memcpyFromQueue(
      frame,
      _VirtioNet.transmitQueueIdx,
      descIdx,
      _VirtioNet.headerSize,
      frameSize,
    );
    ethernetDevice.writePacket(frame);
    consumeDescriptor(_VirtioNet.transmitQueueIdx, descIdx, 0);
  }
}

VirtioNetDevice createVirtioNet({
  required PhysMemoryMap memMap,
  required EthernetDevice ethernetDevice,
}) {
  return VirtioNetDevice(memMap: memMap, ethernetDevice: ethernetDevice);
}
