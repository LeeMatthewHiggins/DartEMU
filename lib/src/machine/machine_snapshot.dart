import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/device/virtio/virtio_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';

/// An immutable capture of a machine's architectural state.
///
/// Holds everything needed to reconstitute an equivalent `RiscVMachine`: CPU
/// registers and CSRs, the full contents of RAM and block devices, and
/// interrupt-controller, timer, and VirtIO device state. Derived caches
/// (TLBs, predecoded instructions) are intentionally excluded — they are
/// rebuilt on demand after a restore.
///
/// A snapshot is a deep copy, so the source machine may keep running (or
/// be disposed) without affecting it, and a single snapshot can seed any
/// number of independent restored machines.
class MachineSnapshot {
  MachineSnapshot({
    required this.xlen,
    required this.memorySizeMb,
    required this.cpu,
    required this.ramSegments,
    required this.blockDevices,
    required this.rtcTicks,
    required this.timecmpTicks,
    required this.plicPending,
    required this.plicServed,
    required this.virtioDevices,
  });

  final Xlen xlen;
  final int memorySizeMb;
  final CpuSnapshot cpu;

  /// Contents of each RAM range, keyed by physical base address.
  final List<RamSegmentSnapshot> ramSegments;

  /// Full contents of each block device, in registration order.
  final List<Uint8List> blockDevices;

  final int rtcTicks;
  final int timecmpTicks;
  final int plicPending;
  final int plicServed;
  final List<VirtioDeviceSnapshot> virtioDevices;

  /// Approximate size of this snapshot in bytes (RAM + disks dominate).
  int get sizeBytes {
    var total = cpu.regs.length * 8 + cpu.fpRegs.length;
    for (final seg in ramSegments) {
      total += seg.bytes.length;
    }
    for (final disk in blockDevices) {
      total += disk.length;
    }
    return total;
  }
}

/// Captured contents of one RAM range.
class RamSegmentSnapshot {
  RamSegmentSnapshot({required this.addr, required this.bytes});

  final int addr;
  final Uint8List bytes;
}

/// Captured CPU register and CSR state.
class CpuSnapshot {
  CpuSnapshot({
    required this.regs,
    required this.fpRegs,
    required this.pc,
    required this.fflags,
    required this.frm,
    required this.curXlen,
    required this.privilege,
    required this.fs,
    required this.mxl,
    required this.instructionCounter,
    required this.powerDown,
    required this.shutDown,
    required this.pendingException,
    required this.pendingTval,
    required this.loadReservation,
    required this.mstatus,
    required this.mtvec,
    required this.mscratch,
    required this.mepc,
    required this.mcause,
    required this.mtval,
    required this.mhartid,
    required this.misa,
    required this.mie,
    required this.mip,
    required this.medeleg,
    required this.mideleg,
    required this.mcounteren,
    required this.stvec,
    required this.sscratch,
    required this.sepc,
    required this.scause,
    required this.stval,
    required this.satp,
    required this.scounteren,
  });

  final List<int> regs;
  final Uint8List fpRegs;
  final int pc;
  final int fflags;
  final int frm;
  final int curXlen;
  final PrivilegeLevel privilege;
  final int fs;
  final int mxl;
  final int instructionCounter;
  final bool powerDown;
  final bool shutDown;
  final int pendingException;
  final int pendingTval;
  final int loadReservation;

  final int mstatus;
  final int mtvec;
  final int mscratch;
  final int mepc;
  final int mcause;
  final int mtval;
  final int mhartid;
  final int misa;
  final int mie;
  final int mip;
  final int medeleg;
  final int mideleg;
  final int mcounteren;

  final int stvec;
  final int sscratch;
  final int sepc;
  final int scause;
  final int stval;
  final int satp;
  final int scounteren;
}
