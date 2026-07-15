import 'package:dart_emu/src/cpu/mip_callbacks.dart';
import 'package:dart_emu/src/device/irq_signal.dart';
import 'package:dart_emu/src/util/bit_utils.dart';

class Plic {
  Plic({required this.setMip, required this.resetMip});

  final SetMipCallback setMip;
  final ResetMipCallback resetMip;

  int _pendingIrq = 0;
  int _servedIrq = 0;

  IrqSignal irqSource(int irqNum) {
    return IrqSignal(setIrq: _setIrqLevel, irqNum: irqNum);
  }

  int read(int offset, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.claimComplete:
          final mask = _pendingIrq & ~_servedIrq;
          if (mask != 0) {
            final irq = BitUtils.ctz32(mask);
            _servedIrq |= 1 << irq;
            _updateMip();
            return irq;
          }
          return 0;
        default:
          return 0;
      }
    }
    return 0;
  }

  void write(int offset, int value, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.claimComplete:
          _servedIrq &= ~(1 << value);
          _updateMip();
      }
    }
  }

  void _setIrqLevel(int irqNum, int level) {
    if (level != 0) {
      _pendingIrq |= 1 << irqNum;
    } else {
      _pendingIrq &= ~(1 << irqNum);
    }
    _updateMip();
  }

  void _updateMip() {
    final mask = _pendingIrq & ~_servedIrq;
    if (mask != 0) {
      setMip(_MipBits.meip | _MipBits.seip);
    } else {
      resetMip(_MipBits.meip | _MipBits.seip);
    }
  }

  static const hartBase = 0x200000;
  static const size = 0x00400000;
  static const maxSources = 32;

  static const _wordSizeLog2 = 2;
}

class _Offsets {
  static const claimComplete = Plic.hartBase + 4;
}

class _MipBits {
  static const seip = 1 << 9;
  static const meip = 1 << 11;
}
