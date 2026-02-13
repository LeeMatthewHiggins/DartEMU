import 'package:dart_emu/src/device/irq_signal.dart';
import 'package:dart_emu/src/device/pci/pci_bus.dart';

class VirtioBusDef {
  VirtioBusDef({
    this.pciBus,
    this.addr = 0,
    this.irq,
  });

  final PciBus? pciBus;
  final int addr;
  final IrqSignal? irq;

  bool get isPci => pciBus != null;
}
