import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/machine/clint.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/memory_map_layout.dart';

class _FdtTokens {
  static const beginNode = 1;
  static const endNode = 2;
  static const prop = 3;
  static const end = 9;
}

class _FdtFormat {
  static const magic = 0xD00DFEED;
  static const version = 17;
  static const lastCompatVersion = 16;
  static const headerSizeBytes = 40;
  static const reserveEntryBytes = 16;
  static const alignment = 8;
  static const cellBytes = 4;
  static const cellBits = 32;
  static const mask32 = 0xFFFFFFFF;
}

class _DeviceTree {
  static const rootCompatible = 'ucbbar,riscvemu-bar_dev';
  static const rootModel = 'ucbbar,riscvemu-bare';
  static const socCompatPrimary = 'ucbbar,riscvemu-bar-soc';
  static const socCompatSecondary = 'simple-bus';
  static const cpuCompatible = 'riscv';
  static const cpuDeviceType = 'cpu';
  static const cpuStatus = 'okay';
  static const cpuIntcCompatible = 'riscv,cpu-intc';
  static const memoryDeviceType = 'memory';
  static const htifCompatible = 'ucb,htif0';
  static const clintCompatible = 'riscv,clint0';
  static const plicCompatible = 'riscv,plic0';
  static const virtioCompatible = 'virtio,mmio';
  static const mmuTypeSv32 = 'riscv,sv32';
  static const mmuTypeSv48 = 'riscv,sv48';
  static const addressCells = 2;
  static const sizeCells = 2;
  static const cpuAddressCells = 1;
  static const cpuSizeCells = 0;
  static const interruptCells = 1;
  static const clockFrequency = 2000000000;
  static const plicMaxDevices = 31;
  static const isaPrefixRv32 = 'rv32';
  static const isaPrefixRv64 = 'rv64';
  static const isaLetterBase = 0x61;
  static const isaLetterCount = 26;
}

class _InterruptIds {
  static const mSoftware = 3;
  static const mTimer = 7;
  static const sExternal = 9;
  static const mExternal = 11;
}

class FdtBuilder {
  final _structWords = <int>[];
  final _strings = BytesBuilder(copy: false);
  int _openNodeCount = 0;

  Uint8List build({
    required int ramSize,
    required int misa,
    required Xlen xlen,
    int? kernelStart,
    int? kernelSize,
    int? initrdStart,
    int? initrdSize,
    String? cmdLine,
    int virtioCount = 0,
  }) {
    return buildMachineFdt(
      ramSize: ramSize,
      misa: misa,
      xlen: xlen,
      kernelStart: kernelStart,
      kernelSize: kernelSize,
      initrdStart: initrdStart,
      initrdSize: initrdSize,
      cmdLine: cmdLine,
      virtioCount: virtioCount,
    );
  }

  void beginNode(String name) {
    _putWord(_FdtTokens.beginNode);
    _putData(utf8.encode('$name\x00'));
    _openNodeCount++;
  }

  void beginNodeNum(String name, int address) {
    beginNode('$name@${address.toRadixString(16)}');
  }

  void endNode() {
    _putWord(_FdtTokens.endNode);
    _openNodeCount--;
  }

  void propU32(String name, int value) {
    propTab(name, [value]);
  }

  void propU64(String name, int value) {
    propTab(name, [
      (value >> _FdtFormat.cellBits) & _FdtFormat.mask32,
      value & _FdtFormat.mask32,
    ]);
  }

  void propU64Pair(String name, int v0, int v1) {
    propTab(name, [
      (v0 >> _FdtFormat.cellBits) & _FdtFormat.mask32,
      v0 & _FdtFormat.mask32,
      (v1 >> _FdtFormat.cellBits) & _FdtFormat.mask32,
      v1 & _FdtFormat.mask32,
    ]);
  }

  void propStr(String name, String value) {
    _propRaw(name, utf8.encode('$value\x00'));
  }

  void propStrList(String name, List<String> values) {
    final builder = BytesBuilder(copy: false);
    for (final s in values) {
      builder.add(utf8.encode('$s\x00'));
    }
    _propRaw(name, builder.toBytes());
  }

  void propTab(String name, List<int> values) {
    _putWord(_FdtTokens.prop);
    _putWord(values.length * _FdtFormat.cellBytes);
    _putWord(_getStringOffset(name));
    for (final v in values) {
      _putWord(v);
    }
  }

  void propEmpty(String name) {
    _propRaw(name, const <int>[]);
  }

  Uint8List finish() {
    assert(_openNodeCount == 0, 'Unclosed FDT nodes');
    _putWord(_FdtTokens.end);

    final structBytes = _structWords.length * _FdtFormat.cellBytes;
    final stringBytes = _strings.length;

    var pos = _FdtFormat.headerSizeBytes;
    final offDtStruct = pos;
    pos += structBytes;
    pos = _align8(pos);

    final offMemRsvmap = pos;
    pos += _FdtFormat.reserveEntryBytes;

    final offDtStrings = pos;
    pos += stringBytes;
    pos = _align8(pos);

    final totalSize = pos;

    final output = Uint8List(totalSize);
    final view = ByteData.sublistView(output);

    _writeHeader(
      view,
      totalSize: totalSize,
      offDtStruct: offDtStruct,
      offDtStrings: offDtStrings,
      offMemRsvmap: offMemRsvmap,
      structSize: structBytes,
      stringsSize: stringBytes,
    );

    _copyStructBlock(output, offDtStruct);

    final stringsData = _strings.toBytes();
    output.setRange(offDtStrings, offDtStrings + stringBytes, stringsData);

    return output;
  }

  Uint8List buildMachineFdt({
    required int ramSize,
    required int misa,
    required Xlen xlen,
    int? kernelStart,
    int? kernelSize,
    int? initrdStart,
    int? initrdSize,
    String? cmdLine,
    int virtioCount = 0,
  }) {
    var currentPhandle = 1;

    beginNode('');
    propU32('#address-cells', _DeviceTree.addressCells);
    propU32('#size-cells', _DeviceTree.sizeCells);
    propStr('compatible', _DeviceTree.rootCompatible);
    propStr('model', _DeviceTree.rootModel);

    _buildCpuNodes(misa, currentPhandle, xlen);
    final intcPhandle = currentPhandle;
    currentPhandle++;

    _buildMemoryNode(ramSize);
    _buildHtifNode();

    _buildSocNode(
      intcPhandle: intcPhandle,
      plicPhandle: currentPhandle,
      virtioCount: virtioCount,
    );

    _buildChosenNode(
      cmdLine: cmdLine,
      kernelStart: kernelStart,
      kernelSize: kernelSize,
      initrdStart: initrdStart,
      initrdSize: initrdSize,
    );

    endNode();

    return finish();
  }

  void _buildCpuNodes(int misa, int intcPhandle, Xlen xlen) {
    final mmuType = switch (xlen) {
      Xlen.rv32 => _DeviceTree.mmuTypeSv32,
      Xlen.rv64 => _DeviceTree.mmuTypeSv48,
    };

    beginNode('cpus');
    propU32('#address-cells', _DeviceTree.cpuAddressCells);
    propU32('#size-cells', _DeviceTree.cpuSizeCells);
    propU32('timebase-frequency', Clint.rtcFreq);

    beginNodeNum('cpu', 0);
    propStr('device_type', _DeviceTree.cpuDeviceType);
    propU32('reg', 0);
    propStr('status', _DeviceTree.cpuStatus);
    propStr('compatible', _DeviceTree.cpuCompatible);
    propStr('riscv,isa', _buildIsaString(misa, xlen));
    propStr('mmu-type', mmuType);
    propU32('clock-frequency', _DeviceTree.clockFrequency);

    beginNode('interrupt-controller');
    propU32('#interrupt-cells', _DeviceTree.interruptCells);
    propEmpty('interrupt-controller');
    propStr('compatible', _DeviceTree.cpuIntcCompatible);
    propU32('phandle', intcPhandle);
    endNode();

    endNode();
    endNode();
  }

  void _buildMemoryNode(int ramSize) {
    beginNodeNum('memory', MemoryMapLayout.ramBaseAddr);
    propStr('device_type', _DeviceTree.memoryDeviceType);
    propU64Pair('reg', MemoryMapLayout.ramBaseAddr, ramSize);
    endNode();
  }

  void _buildHtifNode() {
    beginNode('htif');
    propStr('compatible', _DeviceTree.htifCompatible);
    endNode();
  }

  void _buildSocNode({
    required int intcPhandle,
    required int plicPhandle,
    required int virtioCount,
  }) {
    beginNode('soc');
    propU32('#address-cells', _DeviceTree.addressCells);
    propU32('#size-cells', _DeviceTree.sizeCells);
    propStrList('compatible', [
      _DeviceTree.socCompatPrimary,
      _DeviceTree.socCompatSecondary,
    ]);
    propEmpty('ranges');

    _buildClintNode(intcPhandle);
    _buildPlicNode(intcPhandle, plicPhandle);
    _buildVirtioNodes(plicPhandle, virtioCount);

    endNode();
  }

  void _buildClintNode(int intcPhandle) {
    beginNodeNum('clint', MemoryMapLayout.clintBaseAddr);
    propStr('compatible', _DeviceTree.clintCompatible);
    propTab('interrupts-extended', [
      intcPhandle,
      _InterruptIds.mSoftware,
      intcPhandle,
      _InterruptIds.mTimer,
    ]);
    propU64Pair(
      'reg',
      MemoryMapLayout.clintBaseAddr,
      MemoryMapLayout.clintSize,
    );
    endNode();
  }

  void _buildPlicNode(int intcPhandle, int plicPhandle) {
    beginNodeNum('plic', MemoryMapLayout.plicBaseAddr);
    propU32('#interrupt-cells', _DeviceTree.interruptCells);
    propEmpty('interrupt-controller');
    propStr('compatible', _DeviceTree.plicCompatible);
    propU32('riscv,ndev', _DeviceTree.plicMaxDevices);
    propU64Pair('reg', MemoryMapLayout.plicBaseAddr, MemoryMapLayout.plicSize);
    propTab('interrupts-extended', [
      intcPhandle,
      _InterruptIds.sExternal,
      intcPhandle,
      _InterruptIds.mExternal,
    ]);
    propU32('phandle', plicPhandle);
    endNode();
  }

  void _buildVirtioNodes(int plicPhandle, int virtioCount) {
    for (var i = 0; i < virtioCount; i++) {
      final addr =
          MemoryMapLayout.virtioBaseAddr + i * MemoryMapLayout.virtioSize;
      beginNodeNum('virtio', addr);
      propStr('compatible', _DeviceTree.virtioCompatible);
      propU64Pair('reg', addr, MemoryMapLayout.virtioSize);
      propTab('interrupts-extended', [
        plicPhandle,
        MemoryMapLayout.virtioIrqBase + i,
      ]);
      endNode();
    }
  }

  void _buildChosenNode({
    String? cmdLine,
    int? kernelStart,
    int? kernelSize,
    int? initrdStart,
    int? initrdSize,
  }) {
    beginNode('chosen');
    propStr('bootargs', cmdLine ?? '');

    if (kernelSize != null && kernelSize > 0 && kernelStart != null) {
      propU64('riscv,kernel-start', kernelStart);
      propU64('riscv,kernel-end', kernelStart + kernelSize);
    }

    if (initrdSize != null && initrdSize > 0 && initrdStart != null) {
      propU64('linux,initrd-start', initrdStart);
      propU64('linux,initrd-end', initrdStart + initrdSize);
    }

    endNode();
  }

  String _buildIsaString(int misa, Xlen xlen) {
    final isaPrefix = switch (xlen) {
      Xlen.rv32 => _DeviceTree.isaPrefixRv32,
      Xlen.rv64 => _DeviceTree.isaPrefixRv64,
    };
    final buffer = StringBuffer(isaPrefix);
    for (var i = 0; i < _DeviceTree.isaLetterCount; i++) {
      if ((misa & (1 << i)) != 0) {
        buffer.writeCharCode(_DeviceTree.isaLetterBase + i);
      }
    }
    return buffer.toString();
  }

  void _propRaw(String name, List<int> data) {
    _putWord(_FdtTokens.prop);
    _putWord(data.length);
    _putWord(_getStringOffset(name));
    _putData(data);
  }

  void _putWord(int value) {
    _structWords.add(value);
  }

  void _putData(List<int> data) {
    if (data.isEmpty) return;
    final padded = (data.length + 3) & ~3;
    final buf = Uint8List(padded)..setRange(0, data.length, data);
    final view = ByteData.sublistView(buf);
    for (var i = 0; i < padded; i += _FdtFormat.cellBytes) {
      _structWords.add(view.getUint32(i));
    }
  }

  int _getStringOffset(String name) {
    final existing = _strings.toBytes();
    final nameBytes = utf8.encode(name);
    var pos = 0;
    while (pos < existing.length) {
      var end = pos;
      while (end < existing.length && existing[end] != 0) {
        end++;
      }
      final candidate = existing.sublist(pos, end);
      if (_bytesEqual(candidate, nameBytes)) {
        return pos;
      }
      pos = end + 1;
    }
    final offset = _strings.length;
    _strings
      ..add(nameBytes)
      ..addByte(0);
    return offset;
  }

  void _writeHeader(
    ByteData view, {
    required int totalSize,
    required int offDtStruct,
    required int offDtStrings,
    required int offMemRsvmap,
    required int structSize,
    required int stringsSize,
  }) {
    var offset = 0;
    view.setUint32(offset, _FdtFormat.magic);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, totalSize);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, offDtStruct);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, offDtStrings);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, offMemRsvmap);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, _FdtFormat.version);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, _FdtFormat.lastCompatVersion);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, 0);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, stringsSize);
    offset += _FdtFormat.cellBytes;
    view.setUint32(offset, structSize);
  }

  void _copyStructBlock(Uint8List output, int offset) {
    final view = ByteData.sublistView(output);
    for (var i = 0; i < _structWords.length; i++) {
      view.setUint32(offset + i * _FdtFormat.cellBytes, _structWords[i]);
    }
  }

  static int _align8(int value) {
    return (value + _FdtFormat.alignment - 1) & ~(_FdtFormat.alignment - 1);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
