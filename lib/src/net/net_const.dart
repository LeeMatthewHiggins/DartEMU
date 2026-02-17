import 'dart:typed_data';

/// Ethernet frame type identifiers.
class EtherType {
  static const ipv4 = 0x0800;
  static const arp = 0x0806;
}

/// IP protocol numbers.
class IpProtocol {
  static const icmp = 1;
  static const tcp = 6;
  static const udp = 17;
}

/// User-mode network addresses (10.0.2.0/24, matching QEMU/TinyEMU SLiRP).
class UserNetAddr {
  static final network = Uint8List.fromList([10, 0, 2, 0]);
  static final subnetMask = Uint8List.fromList([255, 255, 255, 0]);
  static final gateway = Uint8List.fromList([10, 0, 2, 2]);
  static final dhcpClient = Uint8List.fromList([10, 0, 2, 15]);
  static final dnsServer = Uint8List.fromList([10, 0, 2, 3]);
  static final broadcast = Uint8List.fromList([10, 0, 2, 255]);
  static const leaseTimeSecs = 86400;
}

/// Well-known MAC addresses for the virtual network.
class UserNetMac {
  static final gateway = Uint8List.fromList(
    [0x52, 0x54, 0x00, 0x12, 0x34, 0x56],
  );
  static final defaultClient = Uint8List.fromList(
    [0x02, 0x00, 0x00, 0x00, 0x00, 0x01],
  );
}

/// ARP operation codes.
class ArpOp {
  static const request = 1;
  static const reply = 2;
}

/// ARP hardware/protocol constants.
class ArpConst {
  static const hardwareTypeEthernet = 1;
  static const protocolTypeIpv4 = 0x0800;
  static const hardwareSize = 6;
  static const protocolSize = 4;
  static const packetSize = 28;
}

/// TCP flag bits.
class TcpFlags {
  static const fin = 0x01;
  static const syn = 0x02;
  static const rst = 0x04;
  static const psh = 0x08;
  static const ack = 0x10;
}

/// DHCP constants.
class DhcpConst {
  static const serverPort = 67;
  static const clientPort = 68;
  static const bootRequest = 1;
  static const bootReply = 2;
  static const magicCookie = <int>[99, 130, 83, 99];
  static const optionSubnetMask = 1;
  static const optionRouter = 3;
  static const optionDns = 6;
  static const optionRequestedIp = 50;
  static const optionLeaseTime = 51;
  static const optionMessageType = 53;
  static const optionServerIdentifier = 54;
  static const optionEnd = 255;
  static const messageDiscover = 1;
  static const messageOffer = 2;
  static const messageRequest = 3;
  static const messageAck = 5;
}

/// DNS constants.
class DnsConst {
  static const port = 53;
  static const headerSize = 12;
  static const typeA = 1;
  static const classIn = 1;
  static const flagsResponse = 0x8180;
  static const defaultTtl = 300;
}
