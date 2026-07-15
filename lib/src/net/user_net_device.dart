import 'dart:typed_data';

import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/net/arp_handler.dart';
import 'package:dart_emu/src/net/backend/net_backend.dart';
import 'package:dart_emu/src/net/dhcp_server.dart';
import 'package:dart_emu/src/net/dns_resolver.dart';
import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/icmp_packet.dart';
import 'package:dart_emu/src/net/ipv4_packet.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:dart_emu/src/net/tcp_session.dart';
import 'package:dart_emu/src/net/udp_packet.dart';

/// User-mode network device implementing [EthernetDevice].
///
/// Provides a virtual 10.0.2.0/24 network with built-in DHCP, DNS,
/// ARP handling, and TCP/UDP proxying through the host's network
/// stack via [NetBackend].
class UserNetDevice extends EthernetDevice {
  UserNetDevice({NetBackend? backend, Uint8List? macAddress})
    : _backend = backend ?? createDefaultNetBackend(),
      _macAddress = macAddress ?? UserNetMac.defaultClient;

  final NetBackend _backend;
  final Uint8List _macAddress;
  final List<Uint8List> _rxQueue = [];
  final Map<String, TcpSession> _tcpSessions = {};
  final List<_PendingDnsQuery> _pendingDnsQueries = [];

  final ArpHandler _arpHandler = ArpHandler(
    gatewayMac: UserNetMac.gateway,
    gatewayIp: UserNetAddr.gateway,
  );

  final DhcpServer _dhcpServer = DhcpServer(
    clientIp: UserNetAddr.dhcpClient,
    serverIp: UserNetAddr.gateway,
    gatewayIp: UserNetAddr.gateway,
    dnsIp: UserNetAddr.dnsServer,
    subnetMask: UserNetAddr.subnetMask,
  );

  final DnsResolver _dnsResolver = DnsResolver();

  @override
  Uint8List get macAddress => _macAddress;

  @override
  void writePacket(Uint8List data) {
    final frame = EthernetFrame.parse(data);
    if (frame == null) return;
    switch (frame.etherType) {
      case EtherType.arp:
        _handleArp(frame);
      case EtherType.ipv4:
        _handleIpv4(frame);
    }
  }

  @override
  bool canDeviceWritePacket() => _rxQueue.isNotEmpty;

  @override
  Uint8List? readPacket() {
    if (_rxQueue.isEmpty) return null;
    return _rxQueue.removeAt(0);
  }

  @override
  void deviceWritePacket(Uint8List data) {
    _rxQueue.add(data);
  }

  @override
  void setCarrier({required bool state}) {}

  @override
  void poll() {
    _backend.poll();
    _pollPendingDns();
    _pollTcpSessions();
  }

  void _pollPendingDns() {
    if (_pendingDnsQueries.isEmpty) return;
    final resolved = <int>[];
    for (var i = 0; i < _pendingDnsQueries.length; i++) {
      final pending = _pendingDnsQueries[i];
      pending.pollCount++;
      if (pending.pollCount > _dnsMaxPolls) {
        resolved.add(i);
        continue;
      }
      final reply = _dnsResolver.handleQuery(
        pending.udp.payload,
        _backend.resolveDns,
      );
      if (reply != null) {
        _enqueueDnsReply(
          pending.frame,
          pending.ip,
          pending.udp.sourcePort,
          reply,
        );
        resolved.add(i);
      }
    }
    for (final i in resolved.reversed) {
      _pendingDnsQueries.removeAt(i);
    }
  }

  void _handleArp(EthernetFrame frame) {
    final reply = _arpHandler.handlePacket(frame);
    if (reply != null) _rxQueue.add(reply);
  }

  void _handleIpv4(EthernetFrame frame) {
    final ip = Ipv4Packet.parse(frame.payload);
    if (ip == null) return;
    switch (ip.protocol) {
      case IpProtocol.icmp:
        _handleIcmp(frame, ip);
      case IpProtocol.udp:
        _handleUdp(frame, ip);
      case IpProtocol.tcp:
        _handleTcp(frame, ip);
    }
  }

  void _handleIcmp(EthernetFrame frame, Ipv4Packet ip) {
    final icmp = IcmpPacket.parse(ip.payload);
    if (icmp == null || !icmp.isEchoRequest) return;
    final reply = IcmpPacket(
      type: IcmpPacket.typeEchoReply,
      code: 0,
      payload: icmp.payload,
    ).encode();
    _enqueueIpReply(frame, ip, IpProtocol.icmp, reply);
  }

  void _handleUdp(EthernetFrame frame, Ipv4Packet ip) {
    final udp = UdpPacket.parse(ip.payload);
    if (udp == null) return;

    if (udp.destinationPort == DhcpConst.serverPort) {
      final reply = _dhcpServer.handlePacket(udp);
      if (reply != null) {
        _enqueueUdpReply(frame, ip, reply);
      }
      return;
    }

    if (udp.destinationPort == DnsConst.port) {
      final reply = _dnsResolver.handleQuery(udp.payload, _backend.resolveDns);
      if (reply != null) {
        _enqueueDnsReply(frame, ip, udp.sourcePort, reply);
      } else {
        _pendingDnsQueries.add(
          _PendingDnsQuery(frame: frame, ip: ip, udp: udp),
        );
      }
      return;
    }

    _backend.sendUdpDatagram(
      ip.destinationIp,
      udp.destinationPort,
      udp.payload,
      (response) {
        _enqueueUdpReply(
          frame,
          ip,
          UdpPacket(
            sourcePort: udp.destinationPort,
            destinationPort: udp.sourcePort,
            payload: response,
          ),
        );
      },
    );
  }

  void _handleTcp(EthernetFrame frame, Ipv4Packet ip) {
    final tcp = TcpPacket.parse(ip.payload);
    if (tcp == null) return;

    final key = tcpSessionKeyOf(
      ip.destinationIp,
      tcp.destinationPort,
      ip.sourceIp,
      tcp.sourcePort,
    );

    if (tcp.isSyn && !tcp.isAck) {
      final handle = _backend.openTcpConnection(
        ip.destinationIp,
        tcp.destinationPort,
      );
      if (handle == null) {
        _enqueueTcpRst(frame, ip, tcp);
        return;
      }
      final session = TcpSession(
        handle: handle,
        remoteIp: ip.destinationIp,
        remotePort: tcp.destinationPort,
        localPort: tcp.sourcePort,
        initialGuestSeq: tcp.seqNum,
      );
      _tcpSessions[key] = session;
      final synAck = session.buildSynAck(tcp);
      _enqueueTcpReply(frame, ip, synAck);
      return;
    }

    final session = _tcpSessions[key];
    if (session == null) {
      _enqueueTcpRst(frame, ip, tcp);
      return;
    }

    final replies = session.handlePacket(tcp);
    for (final reply in replies) {
      _enqueueTcpReply(frame, ip, reply);
    }

    if (session.isClosed) {
      _tcpSessions.remove(key);
    }
  }

  void _pollTcpSessions() {
    final closedKeys = <String>[];
    for (final entry in _tcpSessions.entries) {
      final session = entry.value;
      if (session.handle.hasData) {
        final data = session.handle.receive();
        if (data != null) {
          final packets = session.buildDataPackets(data);
          for (final pkt in packets) {
            _enqueueTcpReplyFromSession(session, pkt);
          }
        }
      }
      if (session.handle.isRemoteClosed &&
          session.state == TcpState.established) {
        final fin = session.buildFinPacket();
        _enqueueTcpReplyFromSession(session, fin);
      }
      if (session.isClosed) {
        closedKeys.add(entry.key);
      }
    }
    for (final key in closedKeys) {
      _tcpSessions.remove(key);
    }
  }

  void _enqueueIpReply(
    EthernetFrame original,
    Ipv4Packet originalIp,
    int protocol,
    Uint8List payload,
  ) {
    final ipReply = Ipv4Packet(
      sourceIp: originalIp.destinationIp,
      destinationIp: originalIp.sourceIp,
      protocol: protocol,
      payload: payload,
    ).encode();
    final ethReply = EthernetFrame(
      destinationMac: original.sourceMac,
      sourceMac: UserNetMac.gateway,
      etherType: EtherType.ipv4,
      payload: ipReply,
    ).encode();
    _rxQueue.add(ethReply);
  }

  void _enqueueUdpReply(
    EthernetFrame original,
    Ipv4Packet originalIp,
    UdpPacket udpReply,
  ) {
    final udpBytes = udpReply.encode(
      sourceIp: originalIp.destinationIp,
      destIp: originalIp.sourceIp,
    );
    _enqueueIpReply(original, originalIp, IpProtocol.udp, udpBytes);
  }

  void _enqueueTcpReply(
    EthernetFrame original,
    Ipv4Packet originalIp,
    TcpPacket tcpReply,
  ) {
    final tcpBytes = tcpReply.encode(
      sourceIp: originalIp.destinationIp,
      destIp: originalIp.sourceIp,
    );
    _enqueueIpReply(original, originalIp, IpProtocol.tcp, tcpBytes);
  }

  void _enqueueTcpReplyFromSession(TcpSession session, TcpPacket tcpReply) {
    final tcpBytes = tcpReply.encode(
      sourceIp: session.remoteIp,
      destIp: UserNetAddr.dhcpClient,
    );
    final ipReply = Ipv4Packet(
      sourceIp: session.remoteIp,
      destinationIp: UserNetAddr.dhcpClient,
      protocol: IpProtocol.tcp,
      payload: tcpBytes,
    ).encode();
    final ethReply = EthernetFrame(
      destinationMac: _macAddress,
      sourceMac: UserNetMac.gateway,
      etherType: EtherType.ipv4,
      payload: ipReply,
    ).encode();
    _rxQueue.add(ethReply);
  }

  void _enqueueTcpRst(
    EthernetFrame original,
    Ipv4Packet originalIp,
    TcpPacket originalTcp,
  ) {
    final rst = TcpPacket(
      sourcePort: originalTcp.destinationPort,
      destinationPort: originalTcp.sourcePort,
      seqNum: 0,
      ackNum: (originalTcp.seqNum + 1) & _seqMask,
      flags: TcpFlags.rst | TcpFlags.ack,
      windowSize: 0,
      payload: Uint8List(0),
    );
    _enqueueTcpReply(original, originalIp, rst);
  }

  void _enqueueDnsReply(
    EthernetFrame original,
    Ipv4Packet originalIp,
    int clientPort,
    Uint8List dnsPayload,
  ) {
    _enqueueUdpReply(
      original,
      originalIp,
      UdpPacket(
        sourcePort: DnsConst.port,
        destinationPort: clientPort,
        payload: dnsPayload,
      ),
    );
  }

  static const _seqMask = 0xFFFFFFFF;
  static const _dnsMaxPolls = 5000;
}

class _PendingDnsQuery {
  _PendingDnsQuery({required this.frame, required this.ip, required this.udp});

  final EthernetFrame frame;
  final Ipv4Packet ip;
  final UdpPacket udp;
  int pollCount = 0;
}
