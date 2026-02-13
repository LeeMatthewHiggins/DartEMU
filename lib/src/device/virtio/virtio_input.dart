import 'package:dart_emu/src/device/virtio/virtio_device.dart';

enum VirtioInputType { keyboard, mouse, tablet }

class VirtioInputDevice extends VirtioDevice {
  VirtioInputDevice({
    required super.memMap,
    required this.inputType,
  });

  final VirtioInputType inputType;

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

  static const _deviceId = 18;
  static const _vendorId = 0xFFFF;
}
