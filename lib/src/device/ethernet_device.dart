import 'dart:typed_data';

/// Interface for a network backend attached to a VirtIO net device.
///
/// The VirtIO device calls [writePacket] when the guest sends a frame.
/// The backend enqueues inbound frames via [deviceWritePacket], which
/// the VirtIO device pulls with [readPacket] during polling.
abstract class EthernetDevice {
  Uint8List get macAddress;

  /// Called by the VirtIO device when the guest transmits a frame.
  void writePacket(Uint8List data);

  /// Whether the backend has buffered frames ready for the guest.
  bool canDeviceWritePacket();

  /// Dequeues the next buffered frame for delivery to the guest.
  Uint8List? readPacket();

  /// Enqueues an inbound frame for delivery to the guest.
  void deviceWritePacket(Uint8List data);

  /// Notifies the backend of link state changes.
  void setCarrier({required bool state});

  /// Polls the backend for pending I/O (e.g. socket reads).
  void poll() {}
}
