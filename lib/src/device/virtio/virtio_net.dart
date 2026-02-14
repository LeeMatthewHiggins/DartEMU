import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

class VirtioNetDevice extends VirtioDevice {
  VirtioNetDevice({
    required super.memMap,
    required this.ethernetDevice,
  });

  final EthernetDevice ethernetDevice;

  @override
  int get deviceId => _deviceId;

  @override
  int get vendorId => _vendorId;

  @override
  int get deviceFeatures => 0;

  @override
  int onDeviceReceive(
    int queueIdx,
    int descIdx,
    int readSize,
    int writeSize,
  ) {
    throw UnimplementedError();
  }

  static const _deviceId = 1;
  static const _vendorId = 0xFFFF;
}

VirtioNetDevice createVirtioNet({
  required PhysMemoryMap memMap,
  required EthernetDevice ethernetDevice,
}) {
  return VirtioNetDevice(memMap: memMap, ethernetDevice: ethernetDevice);
}
