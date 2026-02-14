import 'package:dart_emu/src/device/irq_signal.dart';
import 'package:dart_emu/src/device/pci/pci_device.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';

class PciBus {
  PciBus({
    required this.busNum,
    required this.memMap,
    required List<IrqSignal> irqs,
  })  : _irqs = irqs,
        devices = List<PciDevice?>.filled(_maxDevices, null),
        irqState = List.generate(
          _irqPinCount,
          (_) => List<int>.filled(_irqStateWords, 0),
        );

  final int busNum;
  final PhysMemoryMap memMap;
  final List<PciDevice?> devices;
  final List<List<int>> irqState;
  final List<IrqSignal> _irqs;

  PciDevice registerDevice({
    required int devfn,
    required int vendorId,
    required int deviceId,
    required int classId,
    required int revisionId,
  }) {
    final irqs = List.generate(
      _irqPinCount,
      (pin) => IrqSignal(
        setIrq: (irqNum, level) => _deviceSetIrq(devfn, irqNum, level),
        irqNum: pin,
      ),
    );
    final device = PciDevice(devfn: devfn, irqs: irqs)
      ..setConfig16(_Offsets.vendorId, vendorId)
      ..setConfig16(_Offsets.deviceId, deviceId)
      ..setConfig16(_Offsets.classId, classId)
      ..setConfig8(_Offsets.revisionId, revisionId);
    devices[devfn] = device;
    return device;
  }

  void _deviceSetIrq(int devfn, int irqNum, int level) {
    final mappedIrq = (irqNum + (devfn >> _devfnShift)) & _irqPinMask;
    final word = devfn >> _irqStateWordShift;
    final bit = 1 << (devfn & _irqStateBitMask);

    if (level != 0) {
      irqState[mappedIrq][word] |= bit;
    } else {
      irqState[mappedIrq][word] &= ~bit;
    }

    var irqLevel = 0;
    for (final stateWord in irqState[mappedIrq]) {
      if (stateWord != 0) {
        irqLevel = 1;
        break;
      }
    }
    _irqs[mappedIrq].set(irqLevel);
  }

  static const _maxDevices = 256;
  static const _irqPinCount = 4;
  static const _irqStateWords = 8;
  static const _devfnShift = 3;
  static const _irqPinMask = 3;
  static const _irqStateWordShift = 5;
  static const _irqStateBitMask = 31;
}

class _Offsets {
  static const vendorId = 0x00;
  static const deviceId = 0x02;
  static const revisionId = 0x08;
  static const classId = 0x0A;
}
