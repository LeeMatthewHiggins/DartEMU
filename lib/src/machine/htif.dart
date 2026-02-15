import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';

typedef PowerDownCallback = void Function();

class Htif {
  Htif({this.console, this.onPowerDown});

  final CharacterDevice? console;
  final PowerDownCallback? onPowerDown;

  int _tohostLo = 0;
  int _tohostHi = 0;
  int _fromhostLo = 0;
  int _fromhostHi = 0;

  int read(int offset, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      return switch (offset) {
        _Offsets.tohostLow => _tohostLo,
        _Offsets.tohostHigh => _tohostHi,
        _Offsets.fromhostLow => _fromhostLo,
        _Offsets.fromhostHigh => _fromhostHi,
        _ => 0,
      };
    }
    return 0;
  }

  void write(int offset, int value, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.tohostLow:
          _tohostLo = value & _mask32;
          _processCommand();
        case _Offsets.tohostHigh:
          _tohostHi = value & _mask32;
          _processCommand();
        case _Offsets.fromhostLow:
          _fromhostLo = value & _mask32;
        case _Offsets.fromhostHigh:
          _fromhostHi = value & _mask32;
      }
    }
  }

  void receiveChar(int ch) {
    _fromhostHi = (_Device.console << _HiWordShift.device) |
        (_Cmd.getchar << _HiWordShift.cmd);
    _fromhostLo = ch;
  }

  void _processCommand() {
    final device = (_tohostHi >> _HiWordShift.device) & _byteMask;
    final cmd = (_tohostHi >> _HiWordShift.cmd) & _byteMask;

    if (_tohostHi == 0 && _tohostLo == _shutdownValue) {
      onPowerDown?.call();
      return;
    }

    if (device == _Device.console && cmd == _Cmd.putchar) {
      final ch = _tohostLo & _byteMask;
      console?.writeData(Uint8List.fromList([ch]));
      _tohostLo = 0;
      _tohostHi = 0;
      _fromhostHi = (device << _HiWordShift.device) |
          (cmd << _HiWordShift.cmd);
      _fromhostLo = 0;
      return;
    }

    if (device == _Device.console && cmd == _Cmd.getchar) {
      _tohostLo = 0;
      _tohostHi = 0;
      return;
    }
  }

  static const baseAddr = 0x40008000;
  static const regionSize = 0x1000;

  static const _wordSizeLog2 = 2;
  static const _mask32 = 0xFFFFFFFF;
  static const _byteMask = 0xFF;
  static const _shutdownValue = 1;
}

class _Offsets {
  static const tohostLow = 0;
  static const tohostHigh = 4;
  static const fromhostLow = 8;
  static const fromhostHigh = 12;
}

class _Device {
  static const console = 1;
}

class _Cmd {
  static const getchar = 0;
  static const putchar = 1;
}

class _HiWordShift {
  static const device = 24;
  static const cmd = 16;
}
