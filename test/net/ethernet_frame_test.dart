import 'dart:typed_data';

import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:test/test.dart';

void main() {
  group('EthernetFrame', () {
    final dstMac = Uint8List.fromList(
      [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
    );
    final srcMac = Uint8List.fromList(
      [0x02, 0x00, 0x00, 0x00, 0x00, 0x01],
    );

    test('parse returns null for too-short data', () {
      expect(EthernetFrame.parse(Uint8List(13)), isNull);
      expect(EthernetFrame.parse(Uint8List(0)), isNull);
    });

    test('parse extracts fields from valid frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final frame = EthernetFrame(
        destinationMac: dstMac,
        sourceMac: srcMac,
        etherType: EtherType.ipv4,
        payload: payload,
      );
      final encoded = frame.encode();
      final parsed = EthernetFrame.parse(encoded);

      expect(parsed, isNotNull);
      expect(parsed!.destinationMac, dstMac);
      expect(parsed.sourceMac, srcMac);
      expect(parsed.etherType, EtherType.ipv4);
      expect(parsed.payload, payload);
    });

    test('encode produces correct header size', () {
      final payload = Uint8List.fromList([0xAB]);
      final encoded = EthernetFrame(
        destinationMac: dstMac,
        sourceMac: srcMac,
        etherType: EtherType.arp,
        payload: payload,
      ).encode();

      expect(
        encoded.length,
        EthernetFrame.headerSize + payload.length,
      );
    });

    test('encode/decode roundtrip preserves data', () {
      final payload = Uint8List.fromList(
        List.generate(100, (i) => i & 0xFF),
      );
      final original = EthernetFrame(
        destinationMac: dstMac,
        sourceMac: srcMac,
        etherType: EtherType.arp,
        payload: payload,
      );
      final decoded = EthernetFrame.parse(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.etherType, EtherType.arp);
      expect(decoded.payload, payload);
    });

    test('parse with header-only frame has empty payload', () {
      final encoded = EthernetFrame(
        destinationMac: dstMac,
        sourceMac: srcMac,
        etherType: EtherType.ipv4,
        payload: Uint8List(0),
      ).encode();

      final parsed = EthernetFrame.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.payload, isEmpty);
    });
  });
}
