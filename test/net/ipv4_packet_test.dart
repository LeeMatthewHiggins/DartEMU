import 'dart:typed_data';

import 'package:dart_emu/src/net/ipv4_packet.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:test/test.dart';

void main() {
  group('Ipv4Packet', () {
    final srcIp = Uint8List.fromList([10, 0, 2, 15]);
    final dstIp = Uint8List.fromList([93, 184, 216, 34]);

    test('parse returns null for too-short data', () {
      expect(Ipv4Packet.parse(Uint8List(19)), isNull);
      expect(Ipv4Packet.parse(Uint8List(0)), isNull);
    });

    test('parse extracts fields from valid packet', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final encoded = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.tcp,
        payload: payload,
      ).encode();

      final parsed = Ipv4Packet.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.sourceIp, srcIp);
      expect(parsed.destinationIp, dstIp);
      expect(parsed.protocol, IpProtocol.tcp);
      expect(parsed.payload, payload);
    });

    test('encode sets correct version and IHL', () {
      final encoded = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.udp,
        payload: Uint8List(0),
      ).encode();

      expect(encoded[0], 0x45);
    });

    test('encode sets correct total length', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.udp,
        payload: payload,
      ).encode();

      final totalLength = ByteData.sublistView(encoded).getUint16(2);
      expect(totalLength, 20 + payload.length);
    });

    test('checksum is valid after encode', () {
      final encoded = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.icmp,
        payload: Uint8List.fromList([8, 0, 0, 0]),
      ).encode();

      final header = Uint8List.sublistView(encoded, 0, 20);
      final checksum = Ipv4Packet.computeChecksum(header);
      expect(checksum, 0);
    });

    test('encode/decode roundtrip preserves data', () {
      final payload = Uint8List.fromList(
        List.generate(50, (i) => i & 0xFF),
      );
      final original = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.tcp,
        payload: payload,
        identification: 0x1234,
        ttl: 128,
      );
      final decoded = Ipv4Packet.parse(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.sourceIp, srcIp);
      expect(decoded.destinationIp, dstIp);
      expect(decoded.protocol, IpProtocol.tcp);
      expect(decoded.payload, payload);
      expect(decoded.identification, 0x1234);
      expect(decoded.ttl, 128);
    });

    test('parse rejects truncated total length', () {
      final encoded = Ipv4Packet(
        sourceIp: srcIp,
        destinationIp: dstIp,
        protocol: IpProtocol.udp,
        payload: Uint8List(10),
      ).encode();

      final truncated = Uint8List.sublistView(
        encoded,
        0,
        encoded.length - 5,
      );
      expect(Ipv4Packet.parse(truncated), isNull);
    });
  });
}
