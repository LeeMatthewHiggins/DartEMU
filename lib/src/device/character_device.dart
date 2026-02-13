import 'dart:typed_data';

abstract class CharacterDevice {
  void writeData(Uint8List data);
  Uint8List readData(int maxLength);
}
