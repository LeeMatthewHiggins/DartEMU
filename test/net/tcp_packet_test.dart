import 'dart:typed_data';

import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:test/test.dart';

void main() {
  group('TcpPacket', () {
    test('parse returns null for too-short data', () {
      expect(TcpPacket.parse(Uint8List(19)), isNull);
      expect(TcpPacket.parse(Uint8List(0)), isNull);
    });

    test('parse extracts fields from valid packet', () {
      final payload = Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C]);
      final encoded = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1000,
        ackNum: 2000,
        flags: TcpFlags.ack | TcpFlags.psh,
        windowSize: 65535,
        payload: payload,
      ).encode();

      final parsed = TcpPacket.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.sourcePort, 49152);
      expect(parsed.destinationPort, 80);
      expect(parsed.seqNum, 1000);
      expect(parsed.ackNum, 2000);
      expect(parsed.flags, TcpFlags.ack | TcpFlags.psh);
      expect(parsed.windowSize, 65535);
      expect(parsed.payload, payload);
    });

    test('flag accessors work correctly', () {
      final syn = TcpPacket(
        sourcePort: 1,
        destinationPort: 2,
        seqNum: 0,
        ackNum: 0,
        flags: TcpFlags.syn,
        windowSize: 0,
        payload: Uint8List(0),
      );
      expect(syn.isSyn, isTrue);
      expect(syn.isAck, isFalse);
      expect(syn.isFin, isFalse);
      expect(syn.isRst, isFalse);
      expect(syn.isPsh, isFalse);

      final synAck = TcpPacket(
        sourcePort: 1,
        destinationPort: 2,
        seqNum: 0,
        ackNum: 0,
        flags: TcpFlags.syn | TcpFlags.ack,
        windowSize: 0,
        payload: Uint8List(0),
      );
      expect(synAck.isSyn, isTrue);
      expect(synAck.isAck, isTrue);

      final rst = TcpPacket(
        sourcePort: 1,
        destinationPort: 2,
        seqNum: 0,
        ackNum: 0,
        flags: TcpFlags.rst | TcpFlags.ack,
        windowSize: 0,
        payload: Uint8List(0),
      );
      expect(rst.isRst, isTrue);
      expect(rst.isAck, isTrue);
    });

    test('encode/decode roundtrip preserves data', () {
      final payload = Uint8List.fromList(List.generate(30, (i) => i & 0xFF));
      final original = TcpPacket(
        sourcePort: 8080,
        destinationPort: 443,
        seqNum: 0xDEADBEEF,
        ackNum: 0xCAFEBABE,
        flags: TcpFlags.fin | TcpFlags.ack,
        windowSize: 32768,
        payload: payload,
      );
      final decoded = TcpPacket.parse(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.sourcePort, 8080);
      expect(decoded.destinationPort, 443);
      expect(decoded.seqNum, 0xDEADBEEF);
      expect(decoded.ackNum, 0xCAFEBABE);
      expect(decoded.flags, TcpFlags.fin | TcpFlags.ack);
      expect(decoded.windowSize, 32768);
      expect(decoded.payload, payload);
    });

    test('pseudo-header checksum is computed', () {
      final srcIp = Uint8List.fromList([10, 0, 2, 15]);
      final dstIp = Uint8List.fromList([93, 184, 216, 34]);
      final encoded = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1000,
        ackNum: 0,
        flags: TcpFlags.syn,
        windowSize: 65535,
        payload: Uint8List(0),
      ).encode(sourceIp: srcIp, destIp: dstIp);

      final checksum = ByteData.sublistView(encoded).getUint16(16);
      expect(checksum, isNonZero);
    });

    test('encode without checksum has zero checksum', () {
      final encoded = TcpPacket(
        sourcePort: 80,
        destinationPort: 80,
        seqNum: 0,
        ackNum: 0,
        flags: TcpFlags.ack,
        windowSize: 0,
        payload: Uint8List(0),
      ).encode();

      final checksum = ByteData.sublistView(encoded).getUint16(16);
      expect(checksum, 0);
    });
  });
}
