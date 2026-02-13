typedef PciBarSetCallback = void Function(
  int barNum,
  int addr, {
  required bool enabled,
});

enum PciAddressSpaceType {
  memory(0x00),
  io(0x01),
  memoryPrefetch(0x08);

  const PciAddressSpaceType(this.value);
  final int value;
}

class PciIoRegion {
  PciIoRegion({
    required this.size,
    required this.type,
    this.onBarSet,
  });

  final int size;
  final PciAddressSpaceType type;
  final PciBarSetCallback? onBarSet;
  bool enabled = false;
}
