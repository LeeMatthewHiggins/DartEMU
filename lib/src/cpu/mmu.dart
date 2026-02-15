import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/cpu/tlb.dart';
import 'package:dart_emu/src/machine/phys_memory_range.dart';

enum MemoryAccessType { fetch, read, write }

abstract class Mmu {
  factory Mmu({required RiscVCpuState state}) =>
      state.isRv32 ? _Mmu32(state: state) : _Mmu64(state: state);

  Mmu._(this.state);

  final RiscVCpuState state;

  int translate(int virtualAddr, MemoryAccessType accessType);

  void flushTlb() => state.flushTlb();

  void flushTlbPage(int virtualAddr) {
    final pageTag = virtualAddr & ~TlbConstants.pageMask;
    final tlbIdx = (virtualAddr >> TlbConstants.pageSizeLog2) &
        TlbConstants.indexMask;
    _invalidateIfMatches(state.tlbRead[tlbIdx], pageTag);
    _invalidateIfMatches(state.tlbWrite[tlbIdx], pageTag);
    _invalidateIfMatches(state.tlbCode[tlbIdx], pageTag);
  }

  PrivilegeLevel _effectivePrivilege(
    MemoryAccessType accessType,
  ) {
    if (state.privilege == PrivilegeLevel.machine &&
        accessType != MemoryAccessType.fetch &&
        (state.mstatus & _Mstatus.mprvMask) != 0) {
      final mpp =
          (state.mstatus >> _Mstatus.mppShift) & _Mstatus.privMask;
      return PrivilegeLevel.fromValue(mpp);
    }
    return state.privilege;
  }

  bool _pteIsValid(int pte) =>
      (pte & _Pte.validMask) != 0;

  void _validateLeafXwr(
    int xwr,
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    if (xwr == _Pte.xwrWriteOnly ||
        xwr == _Pte.xwrWriteExecute) {
      _raisePageFault(virtualAddr, accessType);
    }
  }

  void _checkPrivilege(
    int pte,
    MemoryAccessType accessType,
    int virtualAddr,
    PrivilegeLevel effectivePriv,
  ) {
    final isUserPage = (pte & _Pte.userMask) != 0;

    if (effectivePriv == PrivilegeLevel.supervisor) {
      if (isUserPage &&
          (state.mstatus & _Mstatus.sumMask) == 0) {
        _raisePageFault(virtualAddr, accessType);
      }
    } else if (effectivePriv == PrivilegeLevel.user) {
      if (!isUserPage) {
        _raisePageFault(virtualAddr, accessType);
      }
    }
  }

  void _checkPermission(
    int xwr,
    MemoryAccessType accessType,
    int virtualAddr,
  ) {
    var effectiveXwr = xwr;
    if ((state.mstatus & _Mstatus.mxrMask) != 0) {
      effectiveXwr |=
          effectiveXwr >> _Pte.xwrExecuteToReadShift;
    }
    effectiveXwr &= _Pte.xwrMask;

    final accessBit = switch (accessType) {
      MemoryAccessType.read => _Pte.accessBitRead,
      MemoryAccessType.write => _Pte.accessBitWrite,
      MemoryAccessType.fetch => _Pte.accessBitExecute,
    };

    if (((effectiveXwr >> accessBit) & 1) == 0) {
      _raisePageFault(virtualAddr, accessType);
    }
  }

  Never _raisePageFault(
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    throw MmuException(
      virtualAddr,
      accessType,
      MmuFault.pageFault,
    );
  }

  void _invalidateIfMatches(TlbEntry entry, int pageTag) {
    if (entry.virtualTag == pageTag) {
      entry.invalidate();
    }
  }
}

class _Mmu32 extends Mmu {
  _Mmu32({required RiscVCpuState state}) : super._(state);

  @override
  int translate(int virtualAddr, MemoryAccessType accessType) {
    final effectivePriv = _effectivePrivilege(accessType);
    if (effectivePriv == PrivilegeLevel.machine) {
      return virtualAddr;
    }

    final mode = (state.satp >> _Satp32.modeShift) & 1;
    if (mode == 0) return virtualAddr;

    return _walkSv32(virtualAddr, accessType, effectivePriv);
  }

  int _walkSv32(
    int virtualAddr,
    MemoryAccessType accessType,
    PrivilegeLevel effectivePriv,
  ) {
    final rootPpn = state.satp & _Satp32.ppnMask;
    var pageTableBase = rootPpn << _Sv32.pageShift;

    for (var level = _Sv32.rootLevel; level >= 0; level--) {
      final vpnShift =
          _Sv32.pageShift + _Sv32.vpnBits * level;
      final vpn =
          (virtualAddr >> vpnShift) & _Sv32.vpnMask;
      final pteAddr =
          pageTableBase + vpn * _Sv32.pteSizeBytes;

      final pte = _readPte(pteAddr, virtualAddr, accessType);
      if (!_pteIsValid(pte)) {
        _raisePageFault(virtualAddr, accessType);
      }

      final xwr = (pte >> _Pte.readBit) & _Pte.xwrMask;
      if (xwr == 0) {
        pageTableBase =
            _ptePpn(pte) << _Sv32.pageShift;
        continue;
      }

      _validateLeafXwr(xwr, virtualAddr, accessType);
      _checkPrivilege(pte, accessType, virtualAddr, effectivePriv);
      _checkPermission(xwr, accessType, virtualAddr);
      _validateSuperpageAlignment(
        pte, level, virtualAddr, accessType,
      );
      _updateAccessedDirtyBits(
        pteAddr, pte, accessType, virtualAddr,
      );
      return _buildPhysicalAddr(pte, virtualAddr, level);
    }

    _raisePageFault(virtualAddr, accessType);
  }

  int _readPte(
    int pteAddr,
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    final range = state.memMap.findRange(pteAddr);
    if (range is! RamRange) {
      _raisePageFault(virtualAddr, accessType);
    }
    final offset = pteAddr - range.addr;
    return range.byteData.getUint32(offset, Endian.little);
  }

  int _ptePpn(int pte) =>
      (pte >> _Pte.ppnShift) & _Sv32.ppnMask;

  void _validateSuperpageAlignment(
    int pte,
    int level,
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    if (level == 0) return;
    final ppn = _ptePpn(pte);
    final alignMask =
        (1 << (_Sv32.vpnBits * level)) - 1;
    if ((ppn & alignMask) != 0) {
      _raisePageFault(virtualAddr, accessType);
    }
  }

  void _updateAccessedDirtyBits(
    int pteAddr,
    int pte,
    MemoryAccessType accessType,
    int virtualAddr,
  ) {
    final needsAccessed =
        (pte & _Pte.accessedMask) == 0;
    final needsDirty =
        accessType == MemoryAccessType.write &&
            (pte & _Pte.dirtyMask) == 0;
    if (!needsAccessed && !needsDirty) return;

    var updatedPte = pte | _Pte.accessedMask;
    if (accessType == MemoryAccessType.write) {
      updatedPte |= _Pte.dirtyMask;
    }

    final range = state.memMap.findRange(pteAddr);
    if (range is! RamRange) {
      _raisePageFault(virtualAddr, accessType);
    }
    final offset = pteAddr - range.addr;
    range.byteData.setUint32(
      offset,
      updatedPte,
      Endian.little,
    );
  }

  int _buildPhysicalAddr(
    int pte,
    int virtualAddr,
    int level,
  ) {
    final paddr = _ptePpn(pte) << _Sv32.pageShift;
    final shift =
        _Sv32.pageShift + _Sv32.vpnBits * level;
    final vaddrMask = (1 << shift) - 1;
    return (paddr & ~vaddrMask) |
        (virtualAddr & vaddrMask);
  }
}

class _Mmu64 extends Mmu {
  _Mmu64({required RiscVCpuState state}) : super._(state);

  @override
  int translate(int virtualAddr, MemoryAccessType accessType) {
    final effectivePriv = _effectivePrivilege(accessType);
    if (effectivePriv == PrivilegeLevel.machine) {
      return virtualAddr;
    }

    final satpMode = (state.satp >> _Satp64.modeShift) &
        _Satp64.modeMask;
    if (satpMode == 0) return virtualAddr;

    return switch (satpMode) {
      _SatpMode.sv39 =>
        _walkSv39(virtualAddr, accessType, effectivePriv),
      _SatpMode.sv48 =>
        _walkSv48(virtualAddr, accessType),
      _ => throw MmuException(
          virtualAddr,
          accessType,
          MmuFault.accessFault,
        ),
    };
  }

  int _walkSv39(
    int virtualAddr,
    MemoryAccessType accessType,
    PrivilegeLevel effectivePriv,
  ) {
    _validateSv39VirtualAddr(virtualAddr, accessType);
    final rootPpn = state.satp & _Satp64.ppnMask;
    var pageTableBase = rootPpn << _Sv39.pageShift;

    for (var level = _Sv39.rootLevel; level >= 0; level--) {
      final vpn = _extractVpn(virtualAddr, level);
      final pteAddr =
          pageTableBase + vpn * _Sv39.pteSizeBytes;

      final pte = _readPte(pteAddr, virtualAddr, accessType);
      if (!_pteIsValid(pte)) {
        _raisePageFault(virtualAddr, accessType);
      }

      final xwr = (pte >> _Pte.readBit) & _Pte.xwrMask;
      if (xwr == 0) {
        pageTableBase = _ptePpn(pte) << _Sv39.pageShift;
        continue;
      }

      _validateLeafXwr(xwr, virtualAddr, accessType);
      _checkPrivilege(pte, accessType, virtualAddr, effectivePriv);
      _checkPermission(xwr, accessType, virtualAddr);
      _validateSuperpageAlignment(
        pte, level, virtualAddr, accessType,
      );
      _updateAccessedDirtyBits(
        pteAddr, pte, accessType, virtualAddr,
      );
      return _buildPhysicalAddr(pte, virtualAddr, level);
    }

    _raisePageFault(virtualAddr, accessType);
  }

  int _walkSv48(
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    throw UnimplementedError('SV48 page table walk');
  }

  void _validateSv39VirtualAddr(
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    final shifted =
        (virtualAddr << _Sv39.signExtShift) >> _Sv39.signExtShift;
    if (shifted != virtualAddr) {
      _raisePageFault(virtualAddr, accessType);
    }
  }

  int _extractVpn(int virtualAddr, int level) {
    final shift =
        _Sv39.pageShift + _Sv39.vpnBits * level;
    return (virtualAddr >> shift) & _Sv39.vpnMask;
  }

  int _readPte(
    int pteAddr,
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    final range = state.memMap.findRange(pteAddr);
    if (range is! RamRange) {
      _raisePageFault(virtualAddr, accessType);
    }
    final offset = pteAddr - range.addr;
    return range.byteData.getUint64(offset, Endian.little);
  }

  int _ptePpn(int pte) =>
      (pte >> _Pte.ppnShift) & _Sv39.ppnMask;

  void _validateSuperpageAlignment(
    int pte,
    int level,
    int virtualAddr,
    MemoryAccessType accessType,
  ) {
    if (level == 0) return;
    final ppn = _ptePpn(pte);
    final alignMask =
        (1 << (_Sv39.vpnBits * level)) - 1;
    if ((ppn & alignMask) != 0) {
      _raisePageFault(virtualAddr, accessType);
    }
  }

  void _updateAccessedDirtyBits(
    int pteAddr,
    int pte,
    MemoryAccessType accessType,
    int virtualAddr,
  ) {
    final needsAccessed =
        (pte & _Pte.accessedMask) == 0;
    final needsDirty =
        accessType == MemoryAccessType.write &&
            (pte & _Pte.dirtyMask) == 0;
    if (!needsAccessed && !needsDirty) return;

    var updatedPte = pte | _Pte.accessedMask;
    if (accessType == MemoryAccessType.write) {
      updatedPte |= _Pte.dirtyMask;
    }

    final range = state.memMap.findRange(pteAddr);
    if (range is! RamRange) {
      _raisePageFault(virtualAddr, accessType);
    }
    final offset = pteAddr - range.addr;
    range.byteData.setUint64(
      offset,
      updatedPte,
      Endian.little,
    );
  }

  int _buildPhysicalAddr(
    int pte,
    int virtualAddr,
    int level,
  ) {
    final paddr = _ptePpn(pte) << _Sv39.pageShift;
    final shift =
        _Sv39.pageShift + _Sv39.vpnBits * level;
    final vaddrMask = (1 << shift) - 1;
    return (paddr & ~vaddrMask) |
        (virtualAddr & vaddrMask);
  }
}

enum MmuFault { pageFault, accessFault }

class MmuException implements Exception {
  MmuException(this.virtualAddr, this.accessType, this.fault);

  final int virtualAddr;
  final MemoryAccessType accessType;
  final MmuFault fault;

  int get causeCode => switch ((accessType, fault)) {
        (MemoryAccessType.fetch, MmuFault.pageFault) =>
          _ExceptionCause.fetchPageFault,
        (MemoryAccessType.read, MmuFault.pageFault) =>
          _ExceptionCause.loadPageFault,
        (MemoryAccessType.write, MmuFault.pageFault) =>
          _ExceptionCause.storePageFault,
        (MemoryAccessType.fetch, MmuFault.accessFault) =>
          _ExceptionCause.faultFetch,
        (MemoryAccessType.read, MmuFault.accessFault) =>
          _ExceptionCause.faultLoad,
        (MemoryAccessType.write, MmuFault.accessFault) =>
          _ExceptionCause.faultStore,
      };

  @override
  String toString() =>
      'MMU ${fault.name}: ${accessType.name} at '
      '0x${virtualAddr.toRadixString(16)}';
}

class _ExceptionCause {
  static const faultFetch = 0x1;
  static const faultLoad = 0x5;
  static const faultStore = 0x7;
  static const fetchPageFault = 0xC;
  static const loadPageFault = 0xD;
  static const storePageFault = 0xF;
}

class _Satp32 {
  static const modeShift = 31;
  static const ppnMask = (1 << 22) - 1;
}

class _Satp64 {
  static const modeShift = 60;
  static const modeMask = 0xF;
  static const ppnMask = (1 << 44) - 1;
}

class _SatpMode {
  static const sv39 = 8;
  static const sv48 = 9;
}

class _Sv32 {
  static const pageShift = 12;
  static const vpnBits = 10;
  static const vpnMask = (1 << vpnBits) - 1;
  static const levelCount = 2;
  static const rootLevel = levelCount - 1;
  static const pteSizeBytes = 4;
  static const ppnMask = (1 << 22) - 1;
}

class _Sv39 {
  static const pageShift = 12;
  static const vpnBits = 9;
  static const vpnMask = (1 << vpnBits) - 1;
  static const levelCount = 3;
  static const rootLevel = levelCount - 1;
  static const vaWidth = 39;
  static const signExtShift = 64 - vaWidth;
  static const pteSizeBytes = 8;
  static const ppnMask = (1 << 44) - 1;
}

class _Pte {
  static const validMask = 1 << 0;
  static const readBit = 1;
  static const accessedMask = 1 << 6;
  static const dirtyMask = 1 << 7;
  static const userMask = 1 << 4;
  static const xwrMask = 0x7;
  static const xwrWriteOnly = 0x2;
  static const xwrWriteExecute = 0x6;
  static const xwrExecuteToReadShift = 2;
  static const ppnShift = 10;
  static const accessBitRead = 0;
  static const accessBitWrite = 1;
  static const accessBitExecute = 2;
}

class _Mstatus {
  static const mprvMask = 1 << 17;
  static const sumMask = 1 << 18;
  static const mxrMask = 1 << 19;
  static const mppShift = 11;
  static const privMask = 0x3;
}
