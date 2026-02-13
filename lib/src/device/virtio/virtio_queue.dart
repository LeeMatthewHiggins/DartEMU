class QueueState {
  bool ready = false;
  int num = 0;
  int lastAvailIdx = 0;
  int descAddr = 0;
  int availAddr = 0;
  int usedAddr = 0;
  bool manualRecv = false;
}

class VirtioDescriptor {
  VirtioDescriptor({
    required this.addr,
    required this.length,
    required this.flags,
    required this.next,
  });

  final int addr;
  final int length;
  final int flags;
  final int next;

  bool get hasNext => (flags & _Flags.next) != 0;
  bool get isWriteOnly => (flags & _Flags.write) != 0;
  bool get isIndirect => (flags & _Flags.indirect) != 0;
}

class _Flags {
  static const next = 1;
  static const write = 2;
  static const indirect = 4;
}

class VirtioQueueConstants {
  const VirtioQueueConstants._();

  static const maxQueues = 8;
  static const maxQueueNum = 16;
  static const maxConfigSpaceSize = 256;
}
