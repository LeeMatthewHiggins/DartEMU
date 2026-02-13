import 'dart:typed_data';

abstract class EthernetDevice {
  Uint8List get macAddress;
  void writePacket(Uint8List data);
  bool canDeviceWritePacket();
  void deviceWritePacket(Uint8List data);
  void setCarrier({required bool state});
}
