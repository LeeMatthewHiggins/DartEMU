import 'dart:typed_data';

import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/udp_packet.dart';

/// A minimal DHCP server for the virtual network.
///
/// Handles DISCOVER and REQUEST messages, always assigning
/// the fixed IP address [UserNetAddr.dhcpClient].
class DhcpServer {
  const DhcpServer({
    required this.clientIp,
    required this.serverIp,
    required this.gatewayIp,
    required this.dnsIp,
    required this.subnetMask,
  });

  final Uint8List clientIp;
  final Uint8List serverIp;
  final Uint8List gatewayIp;
  final Uint8List dnsIp;
  final Uint8List subnetMask;

  /// Processes a DHCP packet and returns a UDP response, or `null`.
  UdpPacket? handlePacket(UdpPacket request) {
    final data = request.payload;
    if (data.length < _minDhcpSize) return null;
    if (data[0] != DhcpConst.bootRequest) return null;

    final messageType = _findOptionByte(
      data,
      DhcpConst.optionMessageType,
    );
    if (messageType == null) return null;

    final int replyType;
    switch (messageType) {
      case DhcpConst.messageDiscover:
        replyType = DhcpConst.messageOffer;
      case DhcpConst.messageRequest:
        replyType = DhcpConst.messageAck;
      default:
        return null;
    }

    final reply = _buildReply(data, replyType);
    return UdpPacket(
      sourcePort: DhcpConst.serverPort,
      destinationPort: DhcpConst.clientPort,
      payload: reply,
    );
  }

  Uint8List _buildReply(Uint8List request, int messageType) {
    final reply = Uint8List(_replySize)
      ..[0] = DhcpConst.bootReply
      ..[1] = request[1] // hardware type
      ..[2] = request[2] // hardware address length
      // Copy transaction ID (bytes 4-7).
      ..setRange(4, 8, Uint8List.sublistView(request, 4, 8))
      // yiaddr: your IP address (bytes 16-19).
      ..setRange(_yiaddrOffset, _yiaddrOffset + 4, clientIp)
      // siaddr: server IP address (bytes 20-23).
      ..setRange(_siaddrOffset, _siaddrOffset + 4, serverIp)
      // chaddr: client hardware address (bytes 28-43).
      ..setRange(
        _chaddrOffset,
        _chaddrOffset + _chaddrSize,
        Uint8List.sublistView(
          request,
          _chaddrOffset,
          _chaddrOffset + _chaddrSize,
        ),
      );

    var offset = _optionsOffset;
    // Magic cookie.
    for (final b in DhcpConst.magicCookie) {
      reply[offset++] = b;
    }
    // Message type option.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionMessageType,
      [messageType],
    );
    // Server identifier.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionServerIdentifier,
      serverIp,
    );
    // Lease time.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionLeaseTime,
      _uint32Bytes(UserNetAddr.leaseTimeSecs),
    );
    // Subnet mask.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionSubnetMask,
      subnetMask,
    );
    // Router.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionRouter,
      gatewayIp,
    );
    // DNS server.
    offset = _writeOption(
      reply,
      offset,
      DhcpConst.optionDns,
      dnsIp,
    );
    // End option.
    reply[offset] = DhcpConst.optionEnd;

    return reply;
  }

  static int _writeOption(
    Uint8List buf,
    int offset,
    int code,
    List<int> data,
  ) {
    buf[offset] = code;
    buf[offset + 1] = data.length;
    buf.setRange(offset + 2, offset + 2 + data.length, data);
    return offset + 2 + data.length;
  }

  static List<int> _uint32Bytes(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static int? _findOptionByte(Uint8List data, int optionCode) {
    var offset = _optionsOffset + 4; // skip magic cookie
    while (offset < data.length) {
      final code = data[offset];
      if (code == DhcpConst.optionEnd) break;
      if (code == 0) {
        offset++;
        continue;
      }
      if (offset + 1 >= data.length) break;
      final length = data[offset + 1];
      if (code == optionCode && length >= 1) {
        return data[offset + 2];
      }
      offset += 2 + length;
    }
    return null;
  }

  static const _minDhcpSize = 240;
  static const _yiaddrOffset = 16;
  static const _siaddrOffset = 20;
  static const _chaddrOffset = 28;
  static const _chaddrSize = 16;
  static const _optionsOffset = 236;
  static const _replySize = 548;
}
