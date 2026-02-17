import 'dart:typed_data';

import 'package:dart_emu/src/net/udp_packet.dart';
import 'package:test/test.dart';

void main() {
  group('UdpPacket', () {
    test('parse returns null for too-short data', () {
      expect(UdpPacket.parse(Uint8List(7)), isNull);
      expect(UdpPacket.parse(Uint8List(0)), isNull);
    });

    test('parse extracts fields from valid packet', () {
      final payload = Uint8List.fromList([0xDE, 0xAD]);
      final encoded = UdpPacket(
        sourcePort: 12345,
        destinationPort: 53,
        payload: payload,
      ).encode();

      final parsed = UdpPacket.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.sourcePort, 12345);
      expect(parsed.destinationPort, 53);
      expect(parsed.payload, payload);
    });

    test('encode/decode roundtrip preserves data', () {
      final payload = Uint8List.fromList(
        List.generate(40, (i) => i & 0xFF),
      );
      final original = UdpPacket(
        sourcePort: 49152,
        destinationPort: 67,
        payload: payload,
      );
      final decoded = UdpPacket.parse(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.sourcePort, 49152);
      expect(decoded.destinationPort, 67);
      expect(decoded.payload, payload);
    });

    test('encode sets correct length field', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final encoded = UdpPacket(
        sourcePort: 1000,
        destinationPort: 2000,
        payload: payload,
      ).encode();

      final length = ByteData.sublistView(encoded).getUint16(4);
      expect(length, UdpPacket.headerSize + payload.length);
    });

    test('pseudo-header checksum is non-zero', () {
      final srcIp = Uint8List.fromList([10, 0, 2, 15]);
      final dstIp = Uint8List.fromList([10, 0, 2, 3]);
      final encoded = UdpPacket(
        sourcePort: 12345,
        destinationPort: 53,
        payload: Uint8List.fromList([1, 2, 3, 4]),
      ).encode(sourceIp: srcIp, destIp: dstIp);

      final checksum = ByteData.sublistView(encoded).getUint16(6);
      expect(checksum, isNonZero);
    });

    test('parse rejects truncated length', () {
      final encoded = UdpPacket(
        sourcePort: 1000,
        destinationPort: 2000,
        payload: Uint8List(20),
      ).encode();

      final truncated = Uint8List.sublistView(
        encoded,
        0,
        encoded.length - 5,
      );
      expect(UdpPacket.parse(truncated), isNull);
    });
  });
}
