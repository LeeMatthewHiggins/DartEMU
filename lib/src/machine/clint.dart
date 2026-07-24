import 'package:dart_emu/src/cpu/mip_callbacks.dart';

class Clint {
  Clint({required this.setMip, required this.resetMip}) {
    _wallClock.start();
  }

  final SetMipCallback setMip;
  final ResetMipCallback resetMip;
  final Stopwatch _wallClock = Stopwatch();

  int _timecmpLow = 0;
  int _timecmpHigh = 0;
  int _baseTicks = 0;

  int get timecmp => _timecmpLow | (_timecmpHigh << _wordBits);

  int get rtcTime =>
      _baseTicks + _wallClock.elapsedMicroseconds * _rtcTicksPerMicrosecond;

  /// Captures the current timer-compare value for snapshotting.
  int get timecmpSnapshot => timecmp;

  /// Restores timer state so guest time resumes from [rtcTicks] rather
  /// than jumping backward to zero, and reinstates the compare value.
  void restoreTime({required int rtcTicks, required int timecmpTicks}) {
    _baseTicks = rtcTicks;
    _wallClock
      ..reset()
      ..start();
    _timecmpLow = timecmpTicks & _mask32;
    _timecmpHigh = (timecmpTicks >> _wordBits) & _mask32;
  }

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
    final time = rtcTime;
    if (time >= (_timecmpLow | (_timecmpHigh << _wordBits))) {
      setMip(_MipBits.mtip);
    }
  }

  static const baseAddr = 0x02000000;
  static const regionSize = 0x000C0000;
  static const rtcFreq = 10000000;

  static const int _rtcTicksPerMicrosecond = rtcFreq ~/ 1000000;
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
  static const int mtip = 1 << 7;
}
