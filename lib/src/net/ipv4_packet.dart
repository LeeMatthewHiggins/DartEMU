import 'dart:typed_data';

/// A parsed IPv4 packet.
class Ipv4Packet {
  const Ipv4Packet({
    required this.sourceIp,
    required this.destinationIp,
    required this.protocol,
    required this.payload,
    this.identification = 0,
    this.ttl = _defaultTtl,
  });

  /// Parses an IPv4 packet from raw bytes.
  ///
  /// Returns `null` if [data] is too short or has an invalid header.
  static Ipv4Packet? parse(Uint8List data) {
    if (data.length < _minHeaderSize) return null;
    final ihl = (data[0] & 0x0F) * 4;
    if (data.length < ihl) return null;
    final view = ByteData.sublistView(data);
    final totalLength = view.getUint16(_totalLengthOffset);
    if (data.length < totalLength) return null;
    return Ipv4Packet(
      identification: view.getUint16(_identificationOffset),
      ttl: data[_ttlOffset],
      protocol: data[_protocolOffset],
      sourceIp: Uint8List.sublistView(data, _srcIpOffset, _dstIpOffset),
      destinationIp: Uint8List.sublistView(
        data,
        _dstIpOffset,
        _dstIpOffset + _ipLength,
      ),
      payload: Uint8List.sublistView(data, ihl, totalLength),
    );
  }

  final Uint8List sourceIp;
  final Uint8List destinationIp;
  final int protocol;
  final Uint8List payload;
  final int identification;
  final int ttl;

  /// Encodes this packet to raw bytes including the IPv4 header.
  Uint8List encode() {
    final totalLength = _minHeaderSize + payload.length;
    final result = Uint8List(totalLength)
      ..[0] = 0x45 // version 4, IHL 5 (20 bytes)
      ..setRange(_srcIpOffset, _dstIpOffset, sourceIp)
      ..setRange(_dstIpOffset, _dstIpOffset + _ipLength, destinationIp)
      ..setRange(_minHeaderSize, totalLength, payload);
    final view = ByteData.sublistView(result)
      ..setUint16(_totalLengthOffset, totalLength)
      ..setUint16(_identificationOffset, identification);
    result[_ttlOffset] = ttl;
    result[_protocolOffset] = protocol;
    final checksum = computeChecksum(
      Uint8List.sublistView(result, 0, _minHeaderSize),
    );
    view.setUint16(_checksumOffset, checksum);
    return result;
  }

  /// Computes the ones-complement checksum over an IPv4 header.
  static int computeChecksum(Uint8List header) {
    var sum = 0;
    final view = ByteData.sublistView(header);
    for (var i = 0; i < header.length - 1; i += 2) {
      sum += view.getUint16(i);
    }
    if (header.length.isOdd) {
      sum += header.last << 8;
    }
    while (sum > 0xFFFF) {
      sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (~sum) & 0xFFFF;
  }

  static const _minHeaderSize = 20;
  static const _totalLengthOffset = 2;
  static const _identificationOffset = 4;
  static const _ttlOffset = 8;
  static const _protocolOffset = 9;
  static const _checksumOffset = 10;
  static const _srcIpOffset = 12;
  static const _dstIpOffset = 16;
  static const _ipLength = 4;
  static const _defaultTtl = 64;
}
