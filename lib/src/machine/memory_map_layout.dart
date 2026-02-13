class MemoryMapLayout {
  const MemoryMapLayout._();

  static const lowRamSize = 0x00010000;
  static const ramBaseAddr = 0x80000000;

  static const clintBaseAddr = 0x02000000;
  static const clintSize = 0x000C0000;

  static const htifBaseAddr = 0x40008000;
  static const htifSize = 0x1000;

  static const virtioBaseAddr = 0x40010000;
  static const virtioSize = 0x1000;
  static const virtioIrqBase = 1;

  static const plicBaseAddr = 0x40100000;
  static const plicSize = 0x00400000;
}
