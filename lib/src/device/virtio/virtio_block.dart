import 'package:dart_emu/src/device/block_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/ram/phys_memory_map.dart';

class VirtioBlockDevice extends VirtioDevice {
  VirtioBlockDevice({
    required super.memMap,
    required this.blockDevice,
  });

  final BlockDevice blockDevice;

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

  static const _deviceId = 2;
  static const _vendorId = 0xFFFF;
}

VirtioBlockDevice createVirtioBlock({
  required PhysMemoryMap memMap,
  required BlockDevice blockDevice,
}) {
  return VirtioBlockDevice(memMap: memMap, blockDevice: blockDevice);
}
