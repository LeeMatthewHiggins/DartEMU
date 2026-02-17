import 'dart:typed_data';

import 'package:dart_emu/src/net/arp_handler.dart';
import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('ArpHandler', () {
    final handler = ArpHandler(
      gatewayMac: UserNetMac.gateway,
      gatewayIp: UserNetAddr.gateway,
    );
    final clientMac = UserNetMac.defaultClient;
    final clientIp = UserNetAddr.dhcpClient;

    test('replies to ARP request with gateway MAC', () {
      final request = buildArpRequest(
        senderMac: clientMac,
        senderIp: clientIp,
        targetIp: UserNetAddr.gateway,
      );
      final frame = EthernetFrame.parse(request)!;

      final replyBytes = handler.handlePacket(frame);
      expect(replyBytes, isNotNull);

      final reply = EthernetFrame.parse(replyBytes!);
      expect(reply, isNotNull);
      expect(reply!.etherType, EtherType.arp);
      expect(reply.destinationMac, clientMac);
      expect(reply.sourceMac, UserNetMac.gateway);

      final arp = reply.payload;
      final view = ByteData.sublistView(arp);
      expect(view.getUint16(6), ArpOp.reply);

      final senderMac = Uint8List.sublistView(arp, 8, 14);
      expect(senderMac, UserNetMac.gateway);

      final senderIp = Uint8List.sublistView(arp, 14, 18);
      expect(senderIp, UserNetAddr.gateway);

      final targetMac = Uint8List.sublistView(arp, 18, 24);
      expect(targetMac, clientMac);

      final targetIpBytes = Uint8List.sublistView(arp, 24, 28);
      expect(targetIpBytes, clientIp);
    });

    test('returns null for non-request ARP', () {
      final arp = Uint8List(28);
      ByteData.sublistView(arp)
        ..setUint16(0, ArpConst.hardwareTypeEthernet)
        ..setUint16(2, ArpConst.protocolTypeIpv4)
        ..setUint16(6, ArpOp.reply);
      arp[4] = 6;
      arp[5] = 4;
      final frame = EthernetFrame(
        destinationMac: UserNetMac.gateway,
        sourceMac: clientMac,
        etherType: EtherType.arp,
        payload: arp,
      );

      expect(handler.handlePacket(frame), isNull);
    });

    test('returns null for too-short ARP payload', () {
      final frame = EthernetFrame(
        destinationMac: UserNetMac.gateway,
        sourceMac: clientMac,
        etherType: EtherType.arp,
        payload: Uint8List(10),
      );

      expect(handler.handlePacket(frame), isNull);
    });

    test('returns null for non-Ethernet hardware type', () {
      final arp = Uint8List(28);
      ByteData.sublistView(arp)
        ..setUint16(0, 99)
        ..setUint16(2, ArpConst.protocolTypeIpv4)
        ..setUint16(6, ArpOp.request);
      arp[4] = 6;
      arp[5] = 4;
      final frame = EthernetFrame(
        destinationMac: UserNetMac.gateway,
        sourceMac: clientMac,
        etherType: EtherType.arp,
        payload: arp,
      );

      expect(handler.handlePacket(frame), isNull);
    });
  });
}
