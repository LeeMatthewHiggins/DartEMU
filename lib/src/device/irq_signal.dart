typedef SetIrqCallback = void Function(int irqNum, int level);

class IrqSignal {
  IrqSignal({
    required SetIrqCallback setIrq,
    required this.irqNum,
  }) : _setIrq = setIrq;

  final SetIrqCallback _setIrq;
  final int irqNum;

  void set(int level) => _setIrq(irqNum, level);
}
