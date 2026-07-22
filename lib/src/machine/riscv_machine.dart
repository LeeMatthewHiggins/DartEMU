import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_executor.dart';
import 'package:dart_emu/src/device/memory_block_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_block.dart';
import 'package:dart_emu/src/device/virtio/virtio_console.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/device/virtio/virtio_net.dart';
import 'package:dart_emu/src/machine/clint.dart';
import 'package:dart_emu/src/machine/fdt_builder.dart';
import 'package:dart_emu/src/machine/htif.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/machine_snapshot.dart';
import 'package:dart_emu/src/machine/memory_map_layout.dart';
import 'package:dart_emu/src/machine/phys_memory_map.dart';
import 'package:dart_emu/src/machine/phys_memory_range.dart';
import 'package:dart_emu/src/machine/plic.dart';

/// A RISC-V virtual machine supporting both RV64 and RV32.
///
/// Construct via [RiscVMachine.fromConfig]. For most use cases, prefer
/// the higher-level `Emulator` facade which manages the execution loop
/// and provides stream-based I/O.
class RiscVMachine {
  RiscVMachine._({
    required this.config,
    required this.memMap,
    required this.cpu,
    required this.plic,
    required this.clint,
    required this.htif,
  });

  factory RiscVMachine.fromConfig(MachineConfig config) =>
      RiscVMachine._skeleton(config).._loadAndBoot();

  /// Restores a machine to the state captured in [snapshot].
  ///
  /// Builds a fresh skeleton from [config] (which must match the one the
  /// snapshot was taken from) without booting, then applies the captured
  /// architectural state. Derived caches (TLBs, predecoded instructions)
  /// are rebuilt lazily on the next step.
  factory RiscVMachine.restore(
    MachineConfig config,
    MachineSnapshot snapshot,
  ) => RiscVMachine._skeleton(config).._applySnapshot(snapshot);

  factory RiscVMachine._skeleton(MachineConfig config) {
    final memMap = PhysMemoryMap();
    final cpu = CpuExecutor(memMap: memMap, xlen: config.xlen);

    final plic = Plic(setMip: cpu.setMip, resetMip: cpu.resetMip);

    final clint = Clint(setMip: cpu.setMip, resetMip: cpu.resetMip);

    cpu.state.rtcTimeRead = () => clint.rtcTime;

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
    ).._registerVirtioDevices();
  }

  final MachineConfig config;
  final PhysMemoryMap memMap;
  final CpuExecutor cpu;
  final Plic plic;
  final Clint clint;
  final Htif htif;
  final List<VirtioDevice> virtioDevices = [];
  VirtioConsoleDevice? _console;
  final List<VirtioNetDevice> _netDevices = [];

  /// Captures the machine's full architectural state.
  ///
  /// The returned snapshot is a deep copy: this machine may keep running
  /// afterwards, and the snapshot can seed any number of independent
  /// [RiscVMachine.restore] instances. Only in-memory block devices are
  /// supported; other device types throw [UnsupportedError].
  MachineSnapshot snapshot() {
    final ramSegments = <RamSegmentSnapshot>[];
    for (final range in memMap.ranges) {
      if (range is RamRange) {
        ramSegments.add(
          RamSegmentSnapshot(
            addr: range.addr,
            bytes: Uint8List.fromList(range.data),
          ),
        );
      }
    }

    final disks = <Uint8List>[];
    for (final device in config.blockDevices) {
      if (device is! MemoryBlockDevice) {
        throw UnsupportedError(
          'snapshot() supports MemoryBlockDevice only, got '
          '${device.runtimeType}',
        );
      }
      disks.add(device.exportBytes());
    }

    final plicState = plic.captureState();
    final s = cpu.state;
    return MachineSnapshot(
      xlen: config.xlen,
      memorySizeMb: config.memorySizeMb,
      cpu: CpuSnapshot(
        regs: List<int>.of(s.regs),
        fpRegs: s.fpRegs.exportBytes(),
        pc: s.pc,
        fflags: s.fflags,
        frm: s.frm,
        curXlen: s.curXlen,
        privilege: s.privilege,
        fs: s.fs,
        mxl: s.mxl,
        instructionCounter: s.instructionCounter,
        powerDown: s.powerDown,
        shutDown: s.shutDown,
        pendingException: s.pendingException,
        pendingTval: s.pendingTval,
        loadReservation: s.loadReservation,
        mstatus: s.mstatus,
        mtvec: s.mtvec,
        mscratch: s.mscratch,
        mepc: s.mepc,
        mcause: s.mcause,
        mtval: s.mtval,
        mhartid: s.mhartid,
        misa: s.misa,
        mie: s.mie,
        mip: s.mip,
        medeleg: s.medeleg,
        mideleg: s.mideleg,
        mcounteren: s.mcounteren,
        stvec: s.stvec,
        sscratch: s.sscratch,
        sepc: s.sepc,
        scause: s.scause,
        stval: s.stval,
        satp: s.satp,
        scounteren: s.scounteren,
      ),
      ramSegments: ramSegments,
      blockDevices: disks,
      rtcTicks: clint.rtcTime,
      timecmpTicks: clint.timecmpSnapshot,
      plicPending: plicState.pending,
      plicServed: plicState.served,
      virtioDevices: [
        for (final device in virtioDevices) device.captureState(),
      ],
    );
  }

  void _applySnapshot(MachineSnapshot snapshot) {
    for (final segment in snapshot.ramSegments) {
      final range = memMap.findRange(segment.addr);
      if (range is! RamRange) {
        throw StateError('no RAM range at 0x${segment.addr.toRadixString(16)}');
      }
      range.data.setAll(0, segment.bytes);
    }

    for (var i = 0; i < config.blockDevices.length; i++) {
      final device = config.blockDevices[i];
      if (device is! MemoryBlockDevice) {
        throw UnsupportedError('restore supports MemoryBlockDevice only');
      }
      device.importBytes(snapshot.blockDevices[i]);
    }

    final s = cpu.state;
    final c = snapshot.cpu;
    s.regs.setAll(0, c.regs);
    s.fpRegs.importBytes(c.fpRegs);
    s
      ..pc = c.pc
      ..fflags = c.fflags
      ..frm = c.frm
      ..curXlen = c.curXlen
      ..privilege = c.privilege
      ..fs = c.fs
      ..mxl = c.mxl
      ..instructionCounter = c.instructionCounter
      ..powerDown = c.powerDown
      ..shutDown = c.shutDown
      ..pendingException = c.pendingException
      ..pendingTval = c.pendingTval
      ..loadReservation = c.loadReservation
      ..mstatus = c.mstatus
      ..mtvec = c.mtvec
      ..mscratch = c.mscratch
      ..mepc = c.mepc
      ..mcause = c.mcause
      ..mtval = c.mtval
      ..mhartid = c.mhartid
      ..misa = c.misa
      ..mie = c.mie
      ..mip = c.mip
      ..medeleg = c.medeleg
      ..mideleg = c.mideleg
      ..mcounteren = c.mcounteren
      ..stvec = c.stvec
      ..sscratch = c.sscratch
      ..sepc = c.sepc
      ..scause = c.scause
      ..stval = c.stval
      ..satp = c.satp
      ..scounteren = c.scounteren;

    clint.restoreTime(
      rtcTicks: snapshot.rtcTicks,
      timecmpTicks: snapshot.timecmpTicks,
    );
    plic.restoreState(
      pending: snapshot.plicPending,
      served: snapshot.plicServed,
    );
    for (var i = 0; i < virtioDevices.length; i++) {
      virtioDevices[i].restoreState(snapshot.virtioDevices[i]);
    }
  }

  void step(int maxCycles) {
    clint.checkTimer();
    _pollConsoleInput();
    _pollNetworkInput();
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

    final input = config.console?.readData(console.writeBufferLength);
    if (input == null || input.isEmpty) return;

    console.writeData(input);
  }

  void _pollNetworkInput() {
    for (final netDevice in _netDevices) {
      final eth = netDevice.ethernetDevice..poll();
      while (netDevice.canReceivePacket && eth.canDeviceWritePacket()) {
        final frame = eth.readPacket();
        if (frame == null) break;
        netDevice.receivePacket(frame);
      }
    }
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

    for (final ethDevice in config.ethDevices) {
      final netDevice = VirtioNetDevice(
        memMap: memMap,
        ethernetDevice: ethDevice,
      );
      _netDevices.add(netDevice);
      _addVirtioDevice(netDevice);
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
    final biosData = _resolveImageData(config.biosData);
    if (biosData == null) return;

    loadBios(biosData);

    final kernelData = _resolveImageData(config.kernelData);

    final kernelOffset =
        (biosData.length + _kernelAlignment - 1) & ~(_kernelAlignment - 1);

    if (kernelData != null) {
      loadKernel(kernelData, biosData.length);
    }

    final fdt = FdtBuilder().build(
      ramSize: config.memorySizeBytes,
      misa: cpu.state.misa,
      xlen: config.xlen,
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
      ..setUint32(_BootInsn.auipcT0Offset, _BootInsn.auipcT0, Endian.little)
      ..setUint32(_BootInsn.auipcA1Offset, _BootInsn.auipcA1, Endian.little)
      ..setUint32(_BootInsn.addiA1Offset, _BootInsn.addiA1, Endian.little)
      ..setUint32(
        _BootInsn.csrrA0Offset,
        _BootInsn.csrrA0Mhartid,
        Endian.little,
      )
      ..setUint32(_BootInsn.jalrT0Offset, _BootInsn.jalrZeroT0, Endian.little);
  }

  Uint8List? _resolveImageData(Uint8List? data) => data;

  int get _kernelAlignment =>
      config.xlen == Xlen.rv32 ? _kernelAlign4Mb : _kernelAlign2Mb;

  static const _kernelAlign2Mb = 2 * 1024 * 1024;
  static const _kernelAlign4Mb = 4 * 1024 * 1024;
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
