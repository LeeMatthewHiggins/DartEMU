import 'dart:typed_data';

import 'package:dart_emu/src/net/icmp_packet.dart';
import 'package:test/test.dart';

void main() {
  group('IcmpPacket', () {
    test('parse returns null for too-short data', () {
      expect(IcmpPacket.parse(Uint8List(3)), isNull);
      expect(IcmpPacket.parse(Uint8List(0)), isNull);
    });

    test('parse extracts echo request fields', () {
      final payload = Uint8List.fromList([0, 1, 0, 1, 0x61, 0x62]);
      final encoded = IcmpPacket(
        type: IcmpPacket.typeEchoRequest,
        code: 0,
        payload: payload,
      ).encode();

      final parsed = IcmpPacket.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.type, IcmpPacket.typeEchoRequest);
      expect(parsed.code, 0);
      expect(parsed.isEchoRequest, isTrue);
      expect(parsed.isEchoReply, isFalse);
      expect(parsed.payload, payload);
    });

    test('encode echo reply roundtrip', () {
      final payload = Uint8List.fromList([0, 1, 0, 1, 0x63]);
      final original = IcmpPacket(
        type: IcmpPacket.typeEchoReply,
        code: 0,
        payload: payload,
      );
      final decoded = IcmpPacket.parse(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.type, IcmpPacket.typeEchoReply);
      expect(decoded.isEchoReply, isTrue);
      expect(decoded.isEchoRequest, isFalse);
      expect(decoded.payload, payload);
    });

    test('encode sets valid checksum', () {
      final encoded = IcmpPacket(
        type: IcmpPacket.typeEchoRequest,
        code: 0,
        payload: Uint8List.fromList([0, 1, 0, 1]),
      ).encode();

      var sum = 0;
      final view = ByteData.sublistView(encoded);
      for (var i = 0; i < encoded.length - 1; i += 2) {
        sum += view.getUint16(i);
      }
      if (encoded.length.isOdd) {
        sum += encoded.last << 8;
      }
      while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
      }
      expect(sum, 0xFFFF);
    });

    test('parse with header-only data', () {
      final encoded = IcmpPacket(
        type: IcmpPacket.typeEchoReply,
        code: 0,
        payload: Uint8List(0),
      ).encode();

      final parsed = IcmpPacket.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.payload, isEmpty);
    });
  });
}
