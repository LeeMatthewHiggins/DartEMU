import 'dart:typed_data';

import 'package:dart_emu/src/device/irq_signal.dart';
import 'package:dart_emu/src/device/pci/pci_bar.dart';

class PciDevice {
  PciDevice({
    required this.devfn,
    required List<IrqSignal> irqs,
  })  : _irqs = irqs,
        config = Uint8List(_configSize),
        ioRegions = List<PciIoRegion?>.filled(_numRegions, null);

  final int devfn;
  final List<IrqSignal> _irqs;
  final Uint8List config;
  final List<PciIoRegion?> ioRegions;
  int nextCapOffset = _initialCapOffset;

  IrqSignal irq(int pin) => _irqs[pin];

  void setConfig8(int offset, int value) {
    config[offset] = value & _byteMask;
  }

  void setConfig16(int offset, int value) {
    config[offset] = value & _byteMask;
    config[offset + 1] = (value >> _byteShift) & _byteMask;
  }

  void setConfig32(int offset, int value) {
    config[offset] = value & _byteMask;
    config[offset + 1] = (value >> _byteShift) & _byteMask;
    config[offset + 2] = (value >> _wordShift) & _byteMask;
    config[offset + 3] = (value >> _word3Shift) & _byteMask;
  }

  int getConfig16(int offset) {
    return config[offset] | (config[offset + 1] << _byteShift);
  }

  int getConfig32(int offset) {
    return config[offset] |
        (config[offset + 1] << _byteShift) |
        (config[offset + 2] << _wordShift) |
        (config[offset + 3] << _word3Shift);
  }

  void registerBar(
    int barNum,
    int size,
    PciAddressSpaceType type,
    PciBarSetCallback onSet,
  ) {
    ioRegions[barNum] = PciIoRegion(
      size: size,
      type: type,
      onBarSet: onSet,
    );
    setConfig32(_barBaseOffset + barNum * _barStride, type.value);
  }

  static const _configSize = 256;
  static const _numRegions = 7;
  static const _initialCapOffset = 0x40;
  static const _barBaseOffset = 0x10;
  static const _barStride = 4;
  static const _byteMask = 0xFF;
  static const _byteShift = 8;
  static const _wordShift = 16;
  static const _word3Shift = 24;
}
