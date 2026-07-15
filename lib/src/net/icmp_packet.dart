import 'dart:typed_data';

/// A parsed ICMP packet.
class IcmpPacket {
  const IcmpPacket({
    required this.type,
    required this.code,
    required this.payload,
  });

  /// Parses an ICMP packet from raw bytes.
  ///
  /// Returns `null` if [data] is too short.
  static IcmpPacket? parse(Uint8List data) {
    if (data.length < _minSize) return null;
    return IcmpPacket(
      type: data[_typeOffset],
      code: data[_codeOffset],
      payload: Uint8List.sublistView(data, _payloadOffset),
    );
  }

  final int type;
  final int code;
  final Uint8List payload;

  bool get isEchoRequest => type == typeEchoRequest;
  bool get isEchoReply => type == typeEchoReply;

  /// Encodes this packet including the ICMP header and checksum.
  Uint8List encode() {
    final totalLength = _payloadOffset + payload.length;
    final result = Uint8List(totalLength);
    result[_typeOffset] = type;
    result[_codeOffset] = code;
    result.setRange(_payloadOffset, totalLength, payload);
    final checksum = _computeChecksum(result);
    ByteData.sublistView(result).setUint16(_checksumOffset, checksum);
    return result;
  }

  static int _computeChecksum(Uint8List data) {
    var sum = 0;
    final view = ByteData.sublistView(data);
    for (var i = 0; i < data.length - 1; i += 2) {
      sum += view.getUint16(i);
    }
    if (data.length.isOdd) {
      sum += data.last << 8;
    }
    while (sum > 0xFFFF) {
      sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (~sum) & 0xFFFF;
  }

  static const typeEchoReply = 0;
  static const typeEchoRequest = 8;
  static const _typeOffset = 0;
  static const _codeOffset = 1;
  static const _checksumOffset = 2;
  static const _payloadOffset = 4;
  static const _minSize = 4;
}
