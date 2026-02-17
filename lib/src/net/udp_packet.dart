import 'dart:typed_data';

/// A parsed UDP datagram.
class UdpPacket {
  const UdpPacket({
    required this.sourcePort,
    required this.destinationPort,
    required this.payload,
  });

  /// Parses a UDP datagram from raw bytes.
  ///
  /// Returns `null` if [data] is too short.
  static UdpPacket? parse(Uint8List data) {
    if (data.length < headerSize) return null;
    final view = ByteData.sublistView(data);
    final length = view.getUint16(_lengthOffset);
    if (data.length < length) return null;
    return UdpPacket(
      sourcePort: view.getUint16(_srcPortOffset),
      destinationPort: view.getUint16(_dstPortOffset),
      payload: Uint8List.sublistView(data, headerSize, length),
    );
  }

  final int sourcePort;
  final int destinationPort;
  final Uint8List payload;

  /// Encodes this datagram including the UDP header.
  ///
  /// If [sourceIp] and [destIp] are provided, a pseudo-header
  /// checksum is computed.
  Uint8List encode({Uint8List? sourceIp, Uint8List? destIp}) {
    final length = headerSize + payload.length;
    final result = Uint8List(length);
    final view = ByteData.sublistView(result)
      ..setUint16(_srcPortOffset, sourcePort)
      ..setUint16(_dstPortOffset, destinationPort)
      ..setUint16(_lengthOffset, length);
    result.setRange(headerSize, length, payload);
    if (sourceIp != null && destIp != null) {
      view.setUint16(
        _checksumOffset,
        _pseudoHeaderChecksum(sourceIp, destIp, result),
      );
    }
    return result;
  }

  static int _pseudoHeaderChecksum(
    Uint8List srcIp,
    Uint8List dstIp,
    Uint8List udpBytes,
  ) {
    var sum = 0;
    for (var i = 0; i < 4; i += 2) {
      sum += (srcIp[i] << 8) | srcIp[i + 1];
      sum += (dstIp[i] << 8) | dstIp[i + 1];
    }
    sum += _udpProtocol;
    sum += udpBytes.length;
    final view = ByteData.sublistView(udpBytes);
    for (var i = 0; i < udpBytes.length - 1; i += 2) {
      sum += view.getUint16(i);
    }
    if (udpBytes.length.isOdd) {
      sum += udpBytes.last << 8;
    }
    while (sum > 0xFFFF) {
      sum = (sum & 0xFFFF) + (sum >> 16);
    }
    final result = (~sum) & 0xFFFF;
    return result == 0 ? 0xFFFF : result;
  }

  static const headerSize = 8;
  static const _srcPortOffset = 0;
  static const _dstPortOffset = 2;
  static const _lengthOffset = 4;
  static const _checksumOffset = 6;
  static const _udpProtocol = 17;
}
