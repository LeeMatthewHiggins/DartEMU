import 'dart:typed_data';

/// Interface for character-oriented I/O devices (e.g. serial console).
abstract class CharacterDevice {
  /// Writes [data] to the device output.
  void writeData(Uint8List data);

  /// Reads up to [maxLength] bytes of pending input from the device.
  Uint8List readData(int maxLength);
}
