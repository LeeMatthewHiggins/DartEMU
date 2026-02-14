import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_executor.dart';
import 'package:dart_emu/src/device/file_block_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_block.dart';
import 'package:dart_emu/src/device/virtio/virtio_console.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/machine/clint.dart';
import 'package:dart_emu/src/machine/fdt_builder.dart';
import 'package:dart_emu/src/machine/htif.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/memory_map_layout.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:dart_emu/src/machine/plic.dart';

class RiscVMachine {
  RiscVMachine._({
    required this.config,
    required this.memMap,
    required this.cpu,
    required this.plic,
    required this.clint,
    required this.htif,
  });

  factory RiscVMachine.fromConfig(MachineConfig config) {
    final memMap = PhysMemoryMap();
    final cpu = CpuExecutor(memMap: memMap);

    final plic = Plic(
      setMip: cpu.setMip,
      resetMip: cpu.resetMip,
    );

    final clint = Clint(
      setMip: cpu.setMip,
      resetMip: cpu.resetMip,
    );

    final htif = Htif(
      console: config.console,
      onPowerDown: () => cpu.state.shutDown = true,
    );

    memMap
      ..registerRam(
        addr: _BootAddr.lowRamBase,
        size: MemoryMapLayout.lowRamSize,
      )
      ..registerRam(
        addr: MemoryMapLayout.ramBaseAddr,
        size: config.memorySizeBytes,
      )
      ..registerDevice(
        addr: MemoryMapLayout.clintBaseAddr,
        size: MemoryMapLayout.clintSize,
        readFunc: clint.read,
        writeFunc: clint.write,
      )
      ..registerDevice(
        addr: MemoryMapLayout.plicBaseAddr,
        size: MemoryMapLayout.plicSize,
        readFunc: plic.read,
        writeFunc: plic.write,
      )
      ..registerDevice(
        addr: MemoryMapLayout.htifBaseAddr,
        size: MemoryMapLayout.htifSize,
        readFunc: htif.read,
        writeFunc: htif.write,
      );

    return RiscVMachine._(
      config: config,
      memMap: memMap,
      cpu: cpu,
      plic: plic,
      clint: clint,
      htif: htif,
    )
      .._registerVirtioDevices()
      .._loadAndBoot();
  }

  final MachineConfig config;
  final PhysMemoryMap memMap;
  final CpuExecutor cpu;
  final Plic plic;
  final Clint clint;
  final Htif htif;
  final List<VirtioDevice> virtioDevices = [];
  VirtioConsoleDevice? _console;

  void step(int maxCycles) {
    clint.checkTimer();
    _pollConsoleInput();
    if (cpu.state.powerDown) {
      if ((cpu.state.mip & cpu.state.mie) != 0) {
        cpu.state.powerDown = false;
      } else {
        return;
      }
    }
    cpu.execute(maxCycles);
  }

  void _pollConsoleInput() {
    final console = _console;
    if (console == null) return;
    if (!console.canWriteData) return;

    final input = config.console?.readData(
      console.writeBufferLength,
    );
    if (input == null || input.isEmpty) return;

    console.writeData(input);
  }

  void loadBios(Uint8List data) {
    final ramPtr = memMap.getRamPointer(MemoryMapLayout.ramBaseAddr);
    if (ramPtr == null) {
      throw StateError('RAM not found at base address');
    }
    ramPtr.setAll(0, data);
  }

  void loadKernel(Uint8List data, int biosLength) {
    final kernelOffset =
        (biosLength + _kernelAlignment - 1) & ~(_kernelAlignment - 1);
    final loadAddr = MemoryMapLayout.ramBaseAddr + kernelOffset;
    final ramPtr = memMap.getRamPointer(loadAddr);
    if (ramPtr == null) {
      throw StateError('RAM not found for kernel at offset');
    }
    ramPtr.setAll(0, data);
  }

  void _registerVirtioDevices() {
    if (config.console != null) {
      final console = VirtioConsoleDevice(
        memMap: memMap,
        characterDevice: config.console!,
      );
      _console = console;
      _addVirtioDevice(console);
    }

    for (final blockDevice in config.blockDevices) {
      _addVirtioDevice(
        VirtioBlockDevice(memMap: memMap, blockDevice: blockDevice),
      );
    }

    for (final drive in config.driveConfigs) {
      final fileBlock = FileBlockDevice.open(drive.file);
      _addVirtioDevice(
        VirtioBlockDevice(memMap: memMap, blockDevice: fileBlock),
      );
    }
  }

  void _addVirtioDevice(VirtioDevice device) {
    final index = virtioDevices.length;
    final addr =
        MemoryMapLayout.virtioBaseAddr + index * MemoryMapLayout.virtioSize;
    final irqNum = MemoryMapLayout.virtioIrqBase + index;

    device.irq = plic.irqSource(irqNum);

    memMap.registerDevice(
      addr: addr,
      size: MemoryMapLayout.virtioSize,
      readFunc: device.readMmio,
      writeFunc: device.writeMmio,
    );

    virtioDevices.add(device);
  }

  void _loadAndBoot() {
    final biosData = _resolveImageData(
      config.biosData,
      config.biosPath,
    );
    if (biosData == null) return;

    loadBios(biosData);

    final kernelData = _resolveImageData(
      config.kernelData,
      config.kernelPath,
    );

    final kernelOffset =
        (biosData.length + _kernelAlignment - 1) & ~(_kernelAlignment - 1);

    if (kernelData != null) {
      loadKernel(kernelData, biosData.length);
    }

    final fdt = FdtBuilder().build(
      ramSize: config.memorySizeBytes,
      misa: cpu.state.misa,
      kernelStart: kernelData != null
          ? MemoryMapLayout.ramBaseAddr + kernelOffset
          : null,
      kernelSize: kernelData?.length,
      cmdLine: config.cmdLine,
      virtioCount: virtioDevices.length,
    );

    _placeFdt(fdt);
    _writeBootTrampoline();

    cpu.state.pc = _BootAddr.trampolineBase;
  }

  void _placeFdt(Uint8List fdt) {
    final ramPtr = memMap.getRamPointer(_BootAddr.fdtBase);
    if (ramPtr == null) {
      throw StateError('Low RAM not found for FDT');
    }
    ramPtr.setAll(0, fdt);
  }

  void _writeBootTrampoline() {
    final ramPtr = memMap.getRamPointer(_BootAddr.trampolineBase);
    if (ramPtr == null) {
      throw StateError('Low RAM not found for boot trampoline');
    }
    ByteData.sublistView(ramPtr)
      ..setUint32(
        _BootInsn.auipcT0Offset,
        _BootInsn.auipcT0,
        Endian.little,
      )
      ..setUint32(
        _BootInsn.auipcA1Offset,
        _BootInsn.auipcA1,
        Endian.little,
      )
      ..setUint32(
        _BootInsn.addiA1Offset,
        _BootInsn.addiA1,
        Endian.little,
      )
      ..setUint32(
        _BootInsn.csrrA0Offset,
        _BootInsn.csrrA0Mhartid,
        Endian.little,
      )
      ..setUint32(
        _BootInsn.jalrT0Offset,
        _BootInsn.jalrZeroT0,
        Endian.little,
      );
  }

  Uint8List? _resolveImageData(
    Uint8List? inMemoryData,
    String? filePath,
  ) {
    if (inMemoryData != null) return inMemoryData;
    if (filePath == null) return null;
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException(
        'Image file not found',
        filePath,
      );
    }
    return file.readAsBytesSync();
  }

  static const _kernelAlignment = 2 * 1024 * 1024;
}

class _BootAddr {
  static const lowRamBase = 0;
  static const trampolineBase = 0x1000;
  static const fdtBase = trampolineBase + _fdtOffset;
  static const _fdtOffset = 8 * 8;
}

class _BootInsn {
  static const auipcT0Offset = 0;
  static const auipcA1Offset = 4;
  static const addiA1Offset = 8;
  static const csrrA0Offset = 12;
  static const jalrT0Offset = 16;

  static const _addiA1Imm =
      _BootAddr.fdtBase - _BootAddr.trampolineBase - auipcA1Offset;

  static const auipcT0 =
      0x297 + MemoryMapLayout.ramBaseAddr - _BootAddr.trampolineBase;
  static const auipcA1 = 0x597;
  static const addiA1 = 0x58593 | (_addiA1Imm << 20);
  static const csrrA0Mhartid = 0xF1402573;
  static const jalrZeroT0 = 0x00028067;
}
