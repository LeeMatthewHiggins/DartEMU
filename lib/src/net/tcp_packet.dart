import 'dart:typed_data';

import 'package:dart_emu/src/net/net_const.dart';

/// A parsed TCP segment.
class TcpPacket {
  const TcpPacket({
    required this.sourcePort,
    required this.destinationPort,
    required this.seqNum,
    required this.ackNum,
    required this.flags,
    required this.windowSize,
    required this.payload,
  });

  /// Parses a TCP segment from raw bytes.
  ///
  /// Returns `null` if [data] is too short or the header is invalid.
  static TcpPacket? parse(Uint8List data) {
    if (data.length < _minHeaderSize) return null;
    final dataOffset = ((data[_dataOffsetByte] >> 4) & 0xF) * 4;
    if (data.length < dataOffset) return null;
    final view = ByteData.sublistView(data);
    return TcpPacket(
      sourcePort: view.getUint16(_srcPortOffset),
      destinationPort: view.getUint16(_dstPortOffset),
      seqNum: view.getUint32(_seqNumOffset),
      ackNum: view.getUint32(_ackNumOffset),
      flags: data[_flagsOffset],
      windowSize: view.getUint16(_windowOffset),
      payload: Uint8List.sublistView(data, dataOffset),
    );
  }

  final int sourcePort;
  final int destinationPort;
  final int seqNum;
  final int ackNum;
  final int flags;
  final int windowSize;
  final Uint8List payload;

  bool get isSyn => (flags & TcpFlags.syn) != 0;
  bool get isAck => (flags & TcpFlags.ack) != 0;
  bool get isFin => (flags & TcpFlags.fin) != 0;
  bool get isRst => (flags & TcpFlags.rst) != 0;
  bool get isPsh => (flags & TcpFlags.psh) != 0;

  /// Encodes this segment including the TCP header.
  ///
  /// If [sourceIp] and [destIp] are provided, a pseudo-header
  /// checksum is computed.
  Uint8List encode({Uint8List? sourceIp, Uint8List? destIp}) {
    final totalLength = _minHeaderSize + payload.length;
    final result = Uint8List(totalLength);
    final view = ByteData.sublistView(result)
      ..setUint16(_srcPortOffset, sourcePort)
      ..setUint16(_dstPortOffset, destinationPort)
      ..setUint32(_seqNumOffset, seqNum)
      ..setUint32(_ackNumOffset, ackNum);
    result[_dataOffsetByte] = _minHeaderWords << 4;
    result[_flagsOffset] = flags;
    view.setUint16(_windowOffset, windowSize);
    result.setRange(_minHeaderSize, totalLength, payload);
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
    Uint8List tcpBytes,
  ) {
    var sum = 0;
    for (var i = 0; i < 4; i += 2) {
      sum += (srcIp[i] << 8) | srcIp[i + 1];
      sum += (dstIp[i] << 8) | dstIp[i + 1];
    }
    sum += _tcpProtocol;
    sum += tcpBytes.length;
    final view = ByteData.sublistView(tcpBytes);
    for (var i = 0; i < tcpBytes.length - 1; i += 2) {
      sum += view.getUint16(i);
    }
    if (tcpBytes.length.isOdd) {
      sum += tcpBytes.last << 8;
    }
    while (sum > 0xFFFF) {
      sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (~sum) & 0xFFFF;
  }

  static const _minHeaderSize = 20;
  static const _minHeaderWords = 5;
  static const _srcPortOffset = 0;
  static const _dstPortOffset = 2;
  static const _seqNumOffset = 4;
  static const _ackNumOffset = 8;
  static const _dataOffsetByte = 12;
  static const _flagsOffset = 13;
  static const _windowOffset = 14;
  static const _checksumOffset = 16;
  static const _tcpProtocol = 6;
}
