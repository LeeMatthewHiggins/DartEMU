import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';
import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/icmp_packet.dart';
import 'package:dart_emu/src/net/ipv4_packet.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:dart_emu/src/net/udp_packet.dart';
import 'package:dart_emu/src/net/user_net_device.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('UserNetDevice integration', () {
    late MockNetBackend backend;
    late UserNetDevice device;
    final clientMac = UserNetMac.defaultClient;
    final clientIp = UserNetAddr.dhcpClient;

    setUp(() {
      backend = MockNetBackend();
      device = UserNetDevice(backend: backend, macAddress: clientMac);
    });

    test('ARP request returns reply with gateway MAC', () {
      final request = buildArpRequest(
        senderMac: clientMac,
        senderIp: clientIp,
        targetIp: UserNetAddr.gateway,
      );
      device.writePacket(request);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!);
      expect(frame, isNotNull);
      expect(frame!.etherType, EtherType.arp);
      expect(frame.sourceMac, UserNetMac.gateway);

      final arp = frame.payload;
      final senderMac = Uint8List.sublistView(arp, 8, 14);
      expect(senderMac, UserNetMac.gateway);
    });

    test('DHCP DISCOVER returns OFFER', () {
      final discover = buildDhcpDiscover(clientMac: clientMac);
      device.writePacket(discover);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      final udp = UdpPacket.parse(ip.payload)!;

      expect(udp.sourcePort, DhcpConst.serverPort);
      expect(udp.destinationPort, DhcpConst.clientPort);

      final dhcp = udp.payload;
      expect(dhcp[0], DhcpConst.bootReply);

      final yiaddr = Uint8List.sublistView(dhcp, 16, 20);
      expect(yiaddr, UserNetAddr.dhcpClient);
    });

    test('DHCP REQUEST returns ACK', () {
      final request = buildDhcpRequest(
        clientMac: clientMac,
        requestedIp: clientIp,
        serverIp: UserNetAddr.gateway,
      );
      device.writePacket(request);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      final udp = UdpPacket.parse(ip.payload)!;
      final dhcp = udp.payload;

      expect(dhcp[0], DhcpConst.bootReply);
      final yiaddr = Uint8List.sublistView(dhcp, 16, 20);
      expect(yiaddr, UserNetAddr.dhcpClient);
    });

    test('ICMP echo request returns echo reply', () {
      final request = buildIcmpEchoRequest(
        srcIp: clientIp,
        dstIp: UserNetAddr.gateway,
        srcMac: clientMac,
        payload: Uint8List.fromList([0, 1, 0, 1, 0x61]),
      );
      device.writePacket(request);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      expect(ip.protocol, IpProtocol.icmp);

      final icmp = IcmpPacket.parse(ip.payload)!;
      expect(icmp.isEchoReply, isTrue);
      expect(icmp.payload, Uint8List.fromList([0, 1, 0, 1, 0x61]));
    });

    test('DNS query returns A-record response', () {
      backend.dnsResults['example.com'] = [
        Uint8List.fromList([93, 184, 216, 34]),
      ];

      final query = buildDnsQuery(
        srcIp: clientIp,
        srcMac: clientMac,
        hostname: 'example.com',
      );
      device.writePacket(query);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      final udp = UdpPacket.parse(ip.payload)!;
      expect(udp.sourcePort, DnsConst.port);

      final dns = udp.payload;
      final view = ByteData.sublistView(dns);
      expect(view.getUint16(2), DnsConst.flagsResponse);
      expect(view.getUint16(6), 1);

      final answerIp = Uint8List.sublistView(dns, dns.length - 4);
      expect(answerIp, [93, 184, 216, 34]);
    });

    test('DNS query resolved asynchronously via poll', () {
      // First query: backend returns null (simulating async lookup).
      final query = buildDnsQuery(
        srcIp: clientIp,
        srcMac: clientMac,
        hostname: 'async.example.com',
      );
      device.writePacket(query);

      // No immediate reply — lookup is pending.
      expect(device.readPacket(), isNull);

      // Simulate async lookup completing between steps.
      backend.dnsResults['async.example.com'] = [
        Uint8List.fromList([1, 2, 3, 4]),
      ];
      device.poll();

      // poll() retried the pending query and enqueued the response.
      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      final udp = UdpPacket.parse(ip.payload)!;
      expect(udp.sourcePort, DnsConst.port);

      final dns = udp.payload;
      final answerIp = Uint8List.sublistView(dns, dns.length - 4);
      expect(answerIp, [1, 2, 3, 4]);
    });

    test('TCP SYN with no backend returns RST', () {
      final dstIp = Uint8List.fromList([93, 184, 216, 34]);
      final syn = buildTcpSyn(
        srcIp: clientIp,
        srcMac: clientMac,
        dstIp: dstIp,
        dstPort: 80,
      );
      device.writePacket(syn);

      final reply = device.readPacket();
      expect(reply, isNotNull);

      final frame = EthernetFrame.parse(reply!)!;
      final ip = Ipv4Packet.parse(frame.payload)!;
      final tcp = TcpPacket.parse(ip.payload)!;
      expect(tcp.isRst, isTrue);
    });

    test('full TCP download: SYN → SYN-ACK → data → FIN', () {
      final dstIp = Uint8List.fromList([93, 184, 216, 34]);
      final mockHandle = FakeTcpHandle();
      backend.tcpHandle = mockHandle;

      // Step 1: Send SYN, expect SYN-ACK.
      final syn = buildTcpSyn(
        srcIp: clientIp,
        srcMac: clientMac,
        dstIp: dstIp,
        dstPort: 80,
      );
      device.writePacket(syn);

      final synAckBytes = device.readPacket();
      expect(synAckBytes, isNotNull);

      final synAckFrame = EthernetFrame.parse(synAckBytes!)!;
      final synAckIp = Ipv4Packet.parse(synAckFrame.payload)!;
      final synAck = TcpPacket.parse(synAckIp.payload)!;
      expect(synAck.isSyn, isTrue);
      expect(synAck.isAck, isTrue);
      expect(synAck.ackNum, 1001);

      final serverSeq = synAck.seqNum + 1;

      // Step 2: Complete handshake with ACK.
      final ack = buildTcpPacket(
        srcIp: clientIp,
        srcMac: clientMac,
        dstIp: dstIp,
        dstPort: 80,
        srcPort: 49152,
        seqNum: 1001,
        ackNum: serverSeq,
        flags: TcpFlags.ack,
      );
      device.writePacket(ack);
      expect(device.readPacket(), isNull);

      // Step 3: Host sends data via poll().
      final downloadData = Uint8List.fromList('Hello, World!'.codeUnits);
      mockHandle.pendingData = downloadData;
      device.poll();

      final dataReply = device.readPacket();
      expect(dataReply, isNotNull);

      final dataFrame = EthernetFrame.parse(dataReply!)!;
      final dataIp = Ipv4Packet.parse(dataFrame.payload)!;
      final dataTcp = TcpPacket.parse(dataIp.payload)!;
      expect(dataTcp.isAck, isTrue);
      expect(dataTcp.isPsh, isTrue);
      expect(String.fromCharCodes(dataTcp.payload), 'Hello, World!');

      // Step 4: ACK the data.
      final dataAck = buildTcpPacket(
        srcIp: clientIp,
        srcMac: clientMac,
        dstIp: dstIp,
        dstPort: 80,
        srcPort: 49152,
        seqNum: 1001,
        ackNum: serverSeq + downloadData.length,
        flags: TcpFlags.ack,
      );
      device.writePacket(dataAck);

      // Step 5: Host closes connection.
      mockHandle.remoteIsClosed = true;
      device.poll();

      final finBytes = device.readPacket();
      expect(finBytes, isNotNull);

      final finFrame = EthernetFrame.parse(finBytes!)!;
      final finIp = Ipv4Packet.parse(finFrame.payload)!;
      final finTcp = TcpPacket.parse(finIp.payload)!;
      expect(finTcp.isFin, isTrue);
      expect(finTcp.isAck, isTrue);

      // Step 6: Guest sends FIN-ACK.
      final guestFin = buildTcpPacket(
        srcIp: clientIp,
        srcMac: clientMac,
        dstIp: dstIp,
        dstPort: 80,
        srcPort: 49152,
        seqNum: 1001,
        ackNum: finTcp.seqNum + 1,
        flags: TcpFlags.fin | TcpFlags.ack,
      );
      device.writePacket(guestFin);

      // Drain any remaining ACK.
      while (device.readPacket() != null) {}

      // Queue should be empty, session cleaned up.
      expect(device.readPacket(), isNull);
    });

    test('UDP datagram is forwarded to backend', () {
      final dstIp = Uint8List.fromList([8, 8, 8, 8]);
      final udpPayload = Uint8List.fromList([1, 2, 3, 4]);
      final udpEncoded = UdpPacket(
        sourcePort: 5000,
        destinationPort: 9999,
        payload: udpPayload,
      ).encode();
      final ipEncoded = Ipv4Packet(
        sourceIp: clientIp,
        destinationIp: dstIp,
        protocol: IpProtocol.udp,
        payload: udpEncoded,
      ).encode();
      final frame = EthernetFrame(
        destinationMac: UserNetMac.gateway,
        sourceMac: clientMac,
        etherType: EtherType.ipv4,
        payload: ipEncoded,
      ).encode();

      device.writePacket(frame);

      expect(backend.lastUdpDest, dstIp);
      expect(backend.lastUdpPort, 9999);
      expect(backend.lastUdpData, udpPayload);
    });
  });
}

class MockNetBackend implements NetBackend {
  TcpConnectionHandle? tcpHandle;
  Map<String, List<Uint8List>> dnsResults = {};

  Uint8List? lastUdpDest;
  int? lastUdpPort;
  Uint8List? lastUdpData;

  @override
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort) {
    return tcpHandle;
  }

  @override
  void sendUdpDatagram(
    Uint8List destIp,
    int destPort,
    Uint8List data,
    DataCallback onResponse,
  ) {
    lastUdpDest = destIp;
    lastUdpPort = destPort;
    lastUdpData = data;
  }

  @override
  List<Uint8List>? resolveDns(String hostname) {
    return dnsResults[hostname];
  }

  @override
  void poll() {}

  @override
  void dispose() {}
}

class FakeTcpHandle implements TcpConnectionHandle {
  Uint8List? sentData;
  bool closed = false;
  Uint8List? pendingData;
  bool remoteIsClosed = false;

  @override
  void send(Uint8List data) => sentData = data;

  @override
  Uint8List? receive() {
    final data = pendingData;
    pendingData = null;
    return data;
  }

  @override
  bool get isConnected => true;

  @override
  bool get hasData => pendingData != null;

  @override
  bool get isRemoteClosed => remoteIsClosed;

  @override
  void close() => closed = true;
}
