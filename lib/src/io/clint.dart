import 'package:dart_emu/src/cpu/mip_callbacks.dart';

class Clint {
  Clint({
    required this.setMip,
    required this.resetMip,
    required this.getCycles,
  });

  final SetMipCallback setMip;
  final ResetMipCallback resetMip;
  final int Function() getCycles;

  int _timecmpLow = 0;
  int _timecmpHigh = 0;

  int get timecmp => _timecmpLow | (_timecmpHigh << _wordBits);

  int get rtcTime => getCycles() ~/ _rtcFreqDiv;

  int read(int offset, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.mtimeLow:
          return rtcTime & _mask32;
        case _Offsets.mtimeHigh:
          return (rtcTime >> _wordBits) & _mask32;
        case _Offsets.timecmpLow:
          return _timecmpLow;
        case _Offsets.timecmpHigh:
          return _timecmpHigh;
        default:
          return 0;
      }
    }
    return 0;
  }

  void write(int offset, int value, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.timecmpLow:
          _timecmpLow = value & _mask32;
          resetMip(_MipBits.mtip);
        case _Offsets.timecmpHigh:
          _timecmpHigh = value & _mask32;
          resetMip(_MipBits.mtip);
      }
    }
  }

  void checkTimer() {
    if (rtcTime >= timecmp) {
      setMip(_MipBits.mtip);
    }
  }

  static const baseAddr = 0x02000000;
  static const regionSize = 0x000C0000;
  static const rtcFreq = 10000000;

  static const _rtcFreqDiv = 16;
  static const _wordBits = 32;
  static const _mask32 = 0xFFFFFFFF;
  static const _wordSizeLog2 = 2;
}

class _Offsets {
  static const timecmpLow = 0x4000;
  static const timecmpHigh = 0x4004;
  static const mtimeLow = 0xBFF8;
  static const mtimeHigh = 0xBFFC;
}

class _MipBits {
  static const mtip = 1 << 7;
}
