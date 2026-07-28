import 'dart:typed_data';

import 'package:dart_emu/src/cpu/cpu_state.dart';
import 'package:dart_emu/src/device/character_device.dart';

/// Supervisor Binary Interface provided by the emulator itself.
///
/// A RISC-V kernel expects an SBI implementation in machine mode — normally
/// separate firmware such as OpenSBI or BBL. Implementing it here instead
/// means a kernel can be booted directly, with no firmware blob to build,
/// ship or debug, and every call is ordinary Dart that can be traced.
///
/// The scope is deliberately a single hart: inter-processor interrupts and
/// remote fences reduce to local operations, and hart state management has
/// only one hart to describe. Extending to SMP would mean revisiting those.
///
/// Implements SBI v2.0 for the Base, TIME, IPI, RFENCE, HSM, SRST and DBCN
/// extensions, plus the v0.1 legacy calls that early console output uses.
class Sbi {
  Sbi({
    required this.console,
    required this.setTimer,
    required this.shutdown,
    required this.setSupervisorTimerPending,
  });

  /// Console used by the legacy and debug-console extensions.
  final CharacterDevice? console;

  /// Programs the timer compare value, in RTC ticks.
  final void Function(int ticks) setTimer;

  /// Requests machine power-off.
  final void Function() shutdown;

  /// Sets or clears a pending supervisor timer interrupt.
  final void Function({required bool pending}) setSupervisorTimerPending;

  final List<int> _pendingInput = [];

  /// Queues a byte for the legacy `console_getchar` call.
  void receiveChar(int ch) => _pendingInput.add(ch);

  /// Handles an environment call taken from supervisor mode.
  ///
  /// Returns `true` when the call was serviced, in which case the caller
  /// should advance past the `ecall`. Returns `false` to let the normal
  /// exception path run.
  bool handleEcall(RiscVCpuState state) {
    final eid = state.regs[_Reg.a7];
    final fid = state.regs[_Reg.a6];

    if (eid >= _Legacy.setTimer && eid <= _Legacy.shutdown) {
      return _handleLegacy(state, eid);
    }

    return switch (eid) {
      _Eid.base => _handleBase(state, fid),
      _Eid.time => _handleTime(state, fid),
      _Eid.ipi => _reply(state, _Error.success, 0),
      _Eid.rfence => _handleRfence(state, fid),
      _Eid.hsm => _handleHsm(state, fid),
      _Eid.srst => _handleSrst(state),
      _Eid.dbcn => _handleDbcn(state, fid),
      _ => _reply(state, _Error.notSupported, 0),
    };
  }

  bool _handleBase(RiscVCpuState state, int fid) => switch (fid) {
    _BaseFid.getSpecVersion => _reply(state, _Error.success, _specVersion),
    _BaseFid.getImplId => _reply(state, _Error.success, _implId),
    _BaseFid.getImplVersion => _reply(state, _Error.success, _implVersion),
    _BaseFid.probeExtension => _reply(
      state,
      _Error.success,
      _isSupported(state.regs[_Reg.a0]) ? 1 : 0,
    ),
    _BaseFid.getMvendorId ||
    _BaseFid.getMarchId ||
    _BaseFid.getMimpId => _reply(state, _Error.success, 0),
    _ => _reply(state, _Error.notSupported, 0),
  };

  bool _isSupported(int eid) =>
      eid == _Eid.base ||
      eid == _Eid.time ||
      eid == _Eid.ipi ||
      eid == _Eid.rfence ||
      eid == _Eid.hsm ||
      eid == _Eid.srst ||
      eid == _Eid.dbcn ||
      (eid >= _Legacy.setTimer && eid <= _Legacy.shutdown);

  bool _handleTime(RiscVCpuState state, int fid) {
    if (fid != 0) return _reply(state, _Error.notSupported, 0);
    _programTimer(_readTimeArg(state));
    return _reply(state, _Error.success, 0);
  }

  /// Reads the 64-bit `stime_value` argument of a set-timer call.
  ///
  /// SBI passes values wider than a register as two XLEN-sized words, low
  /// half first. On RV64 the whole value fits in `a0`; on RV32 it spans
  /// `a0` and `a1`, and taking only `a0` would wrap the compare value every
  /// 2^32 ticks — about seven minutes at the 10 MHz RTC — after which every
  /// timer is programmed in the past and fires continuously.
  int _readTimeArg(RiscVCpuState state) {
    final low = state.regs[_Reg.a0];
    if (!state.isRv32) return low;
    final high = state.regs[_Reg.a1];
    return (low & _word32Mask) + (high & _word32Mask) * _word32Scale;
  }

  /// Remote fences target other harts; with a single hart the memory model is
  /// already coherent, so these succeed without work.
  bool _handleRfence(RiscVCpuState state, int fid) => fid <= _rfenceMaxFid
      ? _reply(state, _Error.success, 0)
      : _reply(state, _Error.notSupported, 0);

  bool _handleHsm(RiscVCpuState state, int fid) => switch (fid) {
    // Starting or suspending the only hart is not meaningful.
    _HsmFid.hartStart => _reply(state, _Error.alreadyAvailable, 0),
    _HsmFid.hartStop => _reply(state, _Error.failed, 0),
    // The calling hart is by definition started.
    _HsmFid.hartGetStatus => _reply(state, _Error.success, _hartStarted),
    _HsmFid.hartSuspend => _reply(state, _Error.success, 0),
    _ => _reply(state, _Error.notSupported, 0),
  };

  bool _handleSrst(RiscVCpuState state) {
    shutdown();
    return _reply(state, _Error.success, 0);
  }

  /// Debug console extension — the modern replacement for the legacy console
  /// calls, and what current kernels prefer for early output.
  bool _handleDbcn(RiscVCpuState state, int fid) {
    switch (fid) {
      case _DbcnFid.write:
        final len = state.regs[_Reg.a0];
        final addr = state.regs[_Reg.a1];
        var written = 0;
        for (var i = 0; i < len; i++) {
          final byte = state.memMap.physReadU8(addr + i);
          _putChar(byte);
          written++;
        }
        return _reply(state, _Error.success, written);
      case _DbcnFid.read:
        return _reply(state, _Error.success, 0);
      case _DbcnFid.writeByte:
        _putChar(state.regs[_Reg.a0] & 0xFF);
        return _reply(state, _Error.success, 0);
      default:
        return _reply(state, _Error.notSupported, 0);
    }
  }

  /// Legacy v0.1 calls. These return a value directly in `a0` rather than the
  /// error/value pair used by every later extension.
  bool _handleLegacy(RiscVCpuState state, int eid) {
    switch (eid) {
      case _Legacy.setTimer:
        // The legacy call takes the same 64-bit value, split the same way.
        _programTimer(_readTimeArg(state));
        state.regs[_Reg.a0] = 0;
      case _Legacy.consolePutchar:
        _putChar(state.regs[_Reg.a0] & 0xFF);
        state.regs[_Reg.a0] = 0;
      case _Legacy.consoleGetchar:
        state.regs[_Reg.a0] = _pendingInput.isEmpty
            ? -1
            : _pendingInput.removeAt(0);
      case _Legacy.shutdown:
        shutdown();
        state.regs[_Reg.a0] = 0;
      default:
        // clear_ipi, send_ipi and the remote fences are no-ops on one hart.
        state.regs[_Reg.a0] = 0;
    }
    return true;
  }

  void _programTimer(int ticks) {
    setTimer(ticks);
    setSupervisorTimerPending(pending: false);
  }

  void _putChar(int ch) => console?.writeData(Uint8List.fromList([ch & 0xFF]));

  bool _reply(RiscVCpuState state, int error, int value) {
    state.regs[_Reg.a0] = error;
    state.regs[_Reg.a1] = value;
    return true;
  }

  /// SBI v2.0, encoded as major in bits 24-30 and minor in bits 0-23.
  static const int _specVersion = 2 << 24;

  /// Implementation id 9 is unallocated in the SBI specification's list, so
  /// it identifies this emulator without impersonating OpenSBI or BBL.
  static const _implId = 9;
  static const _implVersion = 1;
  static const _hartStarted = 0;
  static const _rfenceMaxFid = 6;
  static const _word32Mask = 0xFFFFFFFF;
  static const int _word32Scale = 0x100000000;
}

class _Reg {
  static const a0 = 10;
  static const a1 = 11;
  static const a6 = 16;
  static const a7 = 17;
}

class _Eid {
  static const base = 0x10;
  static const time = 0x54494D45; // "TIME"
  static const ipi = 0x735049; // "sPI"
  static const rfence = 0x52464E43; // "RFNC"
  static const hsm = 0x48534D; // "HSM"
  static const srst = 0x53525354; // "SRST"
  static const dbcn = 0x4442434E; // "DBCN"
}

class _Legacy {
  static const setTimer = 0x00;
  static const consolePutchar = 0x01;
  static const consoleGetchar = 0x02;
  static const shutdown = 0x08;
}

class _BaseFid {
  static const getSpecVersion = 0;
  static const getImplId = 1;
  static const getImplVersion = 2;
  static const probeExtension = 3;
  static const getMvendorId = 4;
  static const getMarchId = 5;
  static const getMimpId = 6;
}

class _HsmFid {
  static const hartStart = 0;
  static const hartStop = 1;
  static const hartGetStatus = 2;
  static const hartSuspend = 3;
}

class _DbcnFid {
  static const write = 0;
  static const read = 1;
  static const writeByte = 2;
}

class _Error {
  static const success = 0;
  static const failed = -1;
  static const notSupported = -2;
  static const alreadyAvailable = -6;
}
