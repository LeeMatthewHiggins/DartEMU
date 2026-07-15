import 'dart:typed_data';

/// A parsed Ethernet II frame.
class EthernetFrame {
  const EthernetFrame({
    required this.destinationMac,
    required this.sourceMac,
    required this.etherType,
    required this.payload,
  });

  /// Parses an Ethernet frame from raw bytes.
  ///
  /// Returns `null` if [data] is too short to contain a valid header.
  static EthernetFrame? parse(Uint8List data) {
    if (data.length < headerSize) return null;
    final view = ByteData.sublistView(data);
    return EthernetFrame(
      destinationMac: Uint8List.sublistView(data, 0, _macLength),
      sourceMac: Uint8List.sublistView(data, _macLength, _macLength * 2),
      etherType: view.getUint16(_etherTypeOffset),
      payload: Uint8List.sublistView(data, headerSize),
    );
  }

  final Uint8List destinationMac;
  final Uint8List sourceMac;
  final int etherType;
  final Uint8List payload;

  /// Encodes this frame to raw bytes.
  Uint8List encode() {
    return Uint8List(headerSize + payload.length)
      ..setRange(0, _macLength, destinationMac)
      ..setRange(_macLength, _macLength * 2, sourceMac)
      ..[_etherTypeOffset] = etherType >> 8
      ..[_etherTypeOffset + 1] = etherType & 0xFF
      ..setRange(headerSize, headerSize + payload.length, payload);
  }

  static const headerSize = 14;
  static const _macLength = 6;
  static const _etherTypeOffset = 12;
}
