import 'dart:typed_data';

import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/icmp_packet.dart';
import 'package:dart_emu/src/net/ipv4_packet.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:dart_emu/src/net/udp_packet.dart';

Uint8List buildArpRequest({
  required Uint8List senderMac,
  required Uint8List senderIp,
  required Uint8List targetIp,
}) {
  final arp = Uint8List(28)
    ..[4] =
        6 // hardware size
    ..[5] =
        4 // protocol size
    ..setRange(8, 14, senderMac)
    ..setRange(14, 18, senderIp)
    ..setRange(24, 28, targetIp);
  ByteData.sublistView(arp)
    ..setUint16(0, ArpConst.hardwareTypeEthernet)
    ..setUint16(2, ArpConst.protocolTypeIpv4)
    ..setUint16(6, ArpOp.request);
  return EthernetFrame(
    destinationMac: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
    sourceMac: senderMac,
    etherType: EtherType.arp,
    payload: arp,
  ).encode();
}

Uint8List buildDhcpDiscover({required Uint8List clientMac}) {
  final dhcp = Uint8List(548)
    ..[0] = DhcpConst.bootRequest
    ..[1] =
        1 // Ethernet
    ..[2] =
        6 // MAC length
    ..setRange(28, 34, clientMac);
  ByteData.sublistView(dhcp).setUint32(4, 0x12345678);
  // Magic cookie at offset 236.
  dhcp[236] = 99;
  dhcp[237] = 130;
  dhcp[238] = 83;
  dhcp[239] = 99;
  // Option 53: DHCP Message Type = DISCOVER(1).
  dhcp[240] = DhcpConst.optionMessageType;
  dhcp[241] = 1;
  dhcp[242] = DhcpConst.messageDiscover;
  dhcp[243] = DhcpConst.optionEnd;

  final udpPayload = UdpPacket(
    sourcePort: DhcpConst.clientPort,
    destinationPort: DhcpConst.serverPort,
    payload: dhcp,
  ).encode();
  final ipPayload = Ipv4Packet(
    sourceIp: Uint8List.fromList([0, 0, 0, 0]),
    destinationIp: Uint8List.fromList([255, 255, 255, 255]),
    protocol: IpProtocol.udp,
    payload: udpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
    sourceMac: clientMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}

Uint8List buildDhcpRequest({
  required Uint8List clientMac,
  required Uint8List requestedIp,
  required Uint8List serverIp,
}) {
  final dhcp = Uint8List(548)
    ..[0] = DhcpConst.bootRequest
    ..[1] = 1
    ..[2] = 6
    ..setRange(28, 34, clientMac);
  ByteData.sublistView(dhcp).setUint32(4, 0x12345678);
  dhcp[236] = 99;
  dhcp[237] = 130;
  dhcp[238] = 83;
  dhcp[239] = 99;
  // Option 53: REQUEST(3).
  dhcp[240] = DhcpConst.optionMessageType;
  dhcp[241] = 1;
  dhcp[242] = DhcpConst.messageRequest;
  // Option 50: Requested IP.
  dhcp[243] = DhcpConst.optionRequestedIp;
  dhcp[244] = 4;
  dhcp.setRange(245, 249, requestedIp);
  // Option 54: Server Identifier.
  dhcp[249] = DhcpConst.optionServerIdentifier;
  dhcp[250] = 4;
  dhcp.setRange(251, 255, serverIp);
  dhcp[255] = DhcpConst.optionEnd;

  final udpPayload = UdpPacket(
    sourcePort: DhcpConst.clientPort,
    destinationPort: DhcpConst.serverPort,
    payload: dhcp,
  ).encode();
  final ipPayload = Ipv4Packet(
    sourceIp: Uint8List.fromList([0, 0, 0, 0]),
    destinationIp: Uint8List.fromList([255, 255, 255, 255]),
    protocol: IpProtocol.udp,
    payload: udpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
    sourceMac: clientMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}

Uint8List buildIcmpEchoRequest({
  required Uint8List srcIp,
  required Uint8List dstIp,
  required Uint8List srcMac,
  Uint8List? payload,
}) {
  final icmpPayload = IcmpPacket(
    type: IcmpPacket.typeEchoRequest,
    code: 0,
    payload: payload ?? Uint8List.fromList([0, 1, 0, 1, 0x61, 0x62]),
  ).encode();
  final ipPayload = Ipv4Packet(
    sourceIp: srcIp,
    destinationIp: dstIp,
    protocol: IpProtocol.icmp,
    payload: icmpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: UserNetMac.gateway,
    sourceMac: srcMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}

Uint8List buildDnsQuery({
  required Uint8List srcIp,
  required Uint8List srcMac,
  required String hostname,
  int srcPort = 12345,
}) {
  // Build DNS query payload.
  final labels = hostname.split('.');
  final nameBytes = <int>[];
  for (final label in labels) {
    nameBytes
      ..add(label.length)
      ..addAll(label.codeUnits);
  }
  nameBytes.add(0); // null terminator
  final dnsPayload = Uint8List(12 + nameBytes.length + 4);
  ByteData.sublistView(dnsPayload)
    ..setUint16(0, 0x1234) // ID
    ..setUint16(2, 0x0100) // standard query
    ..setUint16(4, 1); // 1 question
  dnsPayload.setRange(12, 12 + nameBytes.length, nameBytes);
  final qOffset = 12 + nameBytes.length;
  ByteData.sublistView(dnsPayload)
    ..setUint16(qOffset, DnsConst.typeA)
    ..setUint16(qOffset + 2, DnsConst.classIn);

  final udpPayload = UdpPacket(
    sourcePort: srcPort,
    destinationPort: DnsConst.port,
    payload: dnsPayload,
  ).encode();
  final ipPayload = Ipv4Packet(
    sourceIp: srcIp,
    destinationIp: UserNetAddr.dnsServer,
    protocol: IpProtocol.udp,
    payload: udpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: UserNetMac.gateway,
    sourceMac: srcMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}

Uint8List buildTcpSyn({
  required Uint8List srcIp,
  required Uint8List srcMac,
  required Uint8List dstIp,
  required int dstPort,
  int srcPort = 49152,
  int seqNum = 1000,
}) {
  final tcpPayload = TcpPacket(
    sourcePort: srcPort,
    destinationPort: dstPort,
    seqNum: seqNum,
    ackNum: 0,
    flags: TcpFlags.syn,
    windowSize: 65535,
    payload: Uint8List(0),
  ).encode(sourceIp: srcIp, destIp: dstIp);
  final ipPayload = Ipv4Packet(
    sourceIp: srcIp,
    destinationIp: dstIp,
    protocol: IpProtocol.tcp,
    payload: tcpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: UserNetMac.gateway,
    sourceMac: srcMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}

Uint8List buildTcpPacket({
  required Uint8List srcIp,
  required Uint8List srcMac,
  required Uint8List dstIp,
  required int dstPort,
  required int srcPort,
  required int seqNum,
  required int ackNum,
  required int flags,
  Uint8List? payload,
}) {
  final tcpPayload = TcpPacket(
    sourcePort: srcPort,
    destinationPort: dstPort,
    seqNum: seqNum,
    ackNum: ackNum,
    flags: flags,
    windowSize: 65535,
    payload: payload ?? Uint8List(0),
  ).encode(sourceIp: srcIp, destIp: dstIp);
  final ipPayload = Ipv4Packet(
    sourceIp: srcIp,
    destinationIp: dstIp,
    protocol: IpProtocol.tcp,
    payload: tcpPayload,
  ).encode();
  return EthernetFrame(
    destinationMac: UserNetMac.gateway,
    sourceMac: srcMac,
    etherType: EtherType.ipv4,
    payload: ipPayload,
  ).encode();
}
