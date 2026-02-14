import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';

typedef PowerDownCallback = void Function();

class Htif {
  Htif({this.console, this.onPowerDown});

  final CharacterDevice? console;
  final PowerDownCallback? onPowerDown;

  int _tohost = 0;
  int _fromhost = 0;

  int read(int offset, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.tohostLow:
          return _tohost & _mask32;
        case _Offsets.tohostHigh:
          return (_tohost >> _wordBits) & _mask32;
        case _Offsets.fromhostLow:
          return _fromhost & _mask32;
        case _Offsets.fromhostHigh:
          return (_fromhost >> _wordBits) & _mask32;
        default:
          return 0;
      }
    }
    return 0;
  }

  void write(int offset, int value, int sizeLog2) {
    if (sizeLog2 == _wordSizeLog2) {
      switch (offset) {
        case _Offsets.tohostLow:
          _tohost = (_tohost & ~_mask32) | (value & _mask32);
          _processCommand();
        case _Offsets.tohostHigh:
          _tohost =
              (_tohost & _mask32) | ((value & _mask32) << _wordBits);
          _processCommand();
        case _Offsets.fromhostLow:
          _fromhost = (_fromhost & ~_mask32) | (value & _mask32);
        case _Offsets.fromhostHigh:
          _fromhost =
              (_fromhost & _mask32) | ((value & _mask32) << _wordBits);
      }
    }
  }

  void receiveChar(int ch) {
    _fromhost =
        (_Device.console << _deviceShift) | (_Cmd.getchar << _cmdShift) | ch;
  }

  void _processCommand() {
    final device = (_tohost >> _deviceShift) & _byteMask;
    final cmd = (_tohost >> _cmdShift) & _byteMask;

    if (_tohost == _shutdownValue) {
      onPowerDown?.call();
      return;
    }

    if (device == _Device.console && cmd == _Cmd.putchar) {
      final ch = _tohost & _dataMask;
      console?.writeData(Uint8List.fromList([ch]));
      _tohost = 0;
      _fromhost =
          (device << _deviceShift) | (cmd << _cmdShift);
      return;
    }

    if (device == _Device.console && cmd == _Cmd.getchar) {
      _tohost = 0;
      return;
    }
  }

  static const baseAddr = 0x40008000;
  static const regionSize = 0x1000;

  static const _wordSizeLog2 = 2;
  static const _mask32 = 0xFFFFFFFF;
  static const _wordBits = 32;
  static const _deviceShift = 56;
  static const _cmdShift = 48;
  static const _byteMask = 0xFF;
  static const _dataMask = 0x0000FFFFFFFFFFFF;
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
