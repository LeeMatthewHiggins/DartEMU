import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';

class ConsoleAdapter implements CharacterDevice {
  final List<int> _inputBuffer = [];

  void feedInput(List<int> bytes) {
    _inputBuffer.addAll(bytes);
  }

  @override
  void writeData(Uint8List data) {
    stdout.add(data);
  }

  @override
  Uint8List readData(int maxLength) {
    if (_inputBuffer.isEmpty) {
      return Uint8List(0);
    }
    final count =
        maxLength < _inputBuffer.length ? maxLength : _inputBuffer.length;
    final result = Uint8List.fromList(
      _inputBuffer.sublist(0, count),
    );
    _inputBuffer.removeRange(0, count);
    return result;
  }
}
