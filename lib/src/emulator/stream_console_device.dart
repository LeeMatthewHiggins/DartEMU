import 'dart:async';
import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';

class StreamConsoleDevice implements CharacterDevice {
  StreamConsoleDevice()
      : _outputController = StreamController<Uint8List>.broadcast();

  final StreamController<Uint8List> _outputController;
  final List<int> _inputBuffer = [];

  Stream<Uint8List> get outputStream => _outputController.stream;

  void feedInput(List<int> bytes) {
    _inputBuffer.addAll(bytes);
  }

  @override
  void writeData(Uint8List data) {
    if (!_outputController.isClosed) {
      _outputController.add(Uint8List.fromList(data));
    }
  }

  @override
  Uint8List readData(int maxLength) {
    if (_inputBuffer.isEmpty) {
      return Uint8List(0);
    }
    final count =
        maxLength < _inputBuffer.length ? maxLength : _inputBuffer.length;
    final result = Uint8List.fromList(_inputBuffer.sublist(0, count));
    _inputBuffer.removeRange(0, count);
    return result;
  }

  Future<void> dispose() async {
    await _outputController.close();
  }
}
