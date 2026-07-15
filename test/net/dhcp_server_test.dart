import 'dart:typed_data';

import 'package:dart_emu/src/net/dhcp_server.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/udp_packet.dart';
import 'package:test/test.dart';

void main() {
  group('DhcpServer', () {
    final server = DhcpServer(
      clientIp: UserNetAddr.dhcpClient,
      serverIp: UserNetAddr.gateway,
      gatewayIp: UserNetAddr.gateway,
      dnsIp: UserNetAddr.dnsServer,
      subnetMask: UserNetAddr.subnetMask,
    );
    final clientMac = UserNetMac.defaultClient;

    UdpPacket buildRequest(int messageType) {
      final dhcp = Uint8List(548)
        ..[0] = DhcpConst.bootRequest
        ..[1] = 1
        ..[2] = 6
        ..setRange(28, 34, clientMac);
      ByteData.sublistView(dhcp).setUint32(4, 0xAABBCCDD);
      dhcp[236] = 99;
      dhcp[237] = 130;
      dhcp[238] = 83;
      dhcp[239] = 99;
      dhcp[240] = DhcpConst.optionMessageType;
      dhcp[241] = 1;
      dhcp[242] = messageType;
      dhcp[243] = DhcpConst.optionEnd;
      return UdpPacket(
        sourcePort: DhcpConst.clientPort,
        destinationPort: DhcpConst.serverPort,
        payload: dhcp,
      );
    }

    test('DISCOVER produces OFFER', () {
      final reply = server.handlePacket(
        buildRequest(DhcpConst.messageDiscover),
      );
      expect(reply, isNotNull);
      expect(reply!.sourcePort, DhcpConst.serverPort);
      expect(reply.destinationPort, DhcpConst.clientPort);

      final data = reply.payload;
      expect(data[0], DhcpConst.bootReply);

      final xid = ByteData.sublistView(data).getUint32(4);
      expect(xid, 0xAABBCCDD);

      final yiaddr = Uint8List.sublistView(data, 16, 20);
      expect(yiaddr, UserNetAddr.dhcpClient);

      final siaddr = Uint8List.sublistView(data, 20, 24);
      expect(siaddr, UserNetAddr.gateway);

      final msgType = _findOption(data, DhcpConst.optionMessageType);
      expect(msgType, [DhcpConst.messageOffer]);
    });

    test('REQUEST produces ACK', () {
      final reply = server.handlePacket(buildRequest(DhcpConst.messageRequest));
      expect(reply, isNotNull);

      final data = reply!.payload;
      expect(data[0], DhcpConst.bootReply);

      final msgType = _findOption(data, DhcpConst.optionMessageType);
      expect(msgType, [DhcpConst.messageAck]);
    });

    test('ACK contains subnet mask, router, and DNS', () {
      final reply = server.handlePacket(
        buildRequest(DhcpConst.messageRequest),
      )!;
      final data = reply.payload;

      final mask = _findOption(data, DhcpConst.optionSubnetMask);
      expect(mask, UserNetAddr.subnetMask);

      final router = _findOption(data, DhcpConst.optionRouter);
      expect(router, UserNetAddr.gateway);

      final dns = _findOption(data, DhcpConst.optionDns);
      expect(dns, UserNetAddr.dnsServer);

      final serverIdBytes = _findOption(data, DhcpConst.optionServerIdentifier);
      expect(serverIdBytes, UserNetAddr.gateway);
    });

    test('copies client hardware address', () {
      final reply = server.handlePacket(
        buildRequest(DhcpConst.messageDiscover),
      )!;
      final chaddr = Uint8List.sublistView(reply.payload, 28, 34);
      expect(chaddr, clientMac);
    });

    test('returns null for too-short DHCP data', () {
      final udp = UdpPacket(
        sourcePort: DhcpConst.clientPort,
        destinationPort: DhcpConst.serverPort,
        payload: Uint8List(100),
      );
      expect(server.handlePacket(udp), isNull);
    });

    test('returns null for boot reply', () {
      final dhcp = Uint8List(548);
      dhcp[0] = DhcpConst.bootReply;
      final udp = UdpPacket(
        sourcePort: DhcpConst.clientPort,
        destinationPort: DhcpConst.serverPort,
        payload: dhcp,
      );
      expect(server.handlePacket(udp), isNull);
    });
  });
}

List<int>? _findOption(Uint8List data, int optionCode) {
  var offset = 240;
  while (offset < data.length) {
    final code = data[offset];
    if (code == DhcpConst.optionEnd) break;
    if (code == 0) {
      offset++;
      continue;
    }
    if (offset + 1 >= data.length) break;
    final length = data[offset + 1];
    if (code == optionCode) {
      return data.sublist(offset + 2, offset + 2 + length);
    }
    offset += 2 + length;
  }
  return null;
}
