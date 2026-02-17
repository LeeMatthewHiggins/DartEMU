import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:dart_emu/src/net/tcp_session.dart';
import 'package:test/test.dart';

void main() {
  group('tcpSessionKeyOf', () {
    test('produces deterministic string key', () {
      final remoteIp = Uint8List.fromList([93, 184, 216, 34]);
      final localIp = Uint8List.fromList([10, 0, 2, 15]);
      final key = tcpSessionKeyOf(remoteIp, 80, localIp, 49152);
      expect(key, '93.184.216.34:80-10.0.2.15:49152');
    });
  });

  group('TcpSession', () {
    late FakeTcpHandle handle;
    late TcpSession session;

    setUp(() {
      handle = FakeTcpHandle();
      session = TcpSession(
        handle: handle,
        remoteIp: Uint8List.fromList([93, 184, 216, 34]),
        remotePort: 80,
        localPort: 49152,
        initialGuestSeq: 1000,
      );
    });

    test('starts in synReceived state', () {
      expect(session.state, TcpState.synReceived);
      expect(session.isClosed, isFalse);
    });

    test('buildSynAck returns SYN-ACK with correct ack', () {
      final syn = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1000,
        ackNum: 0,
        flags: TcpFlags.syn,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      final synAck = session.buildSynAck(syn);

      expect(synAck.isSyn, isTrue);
      expect(synAck.isAck, isTrue);
      expect(synAck.ackNum, 1001);
      expect(synAck.sourcePort, 80);
      expect(synAck.destinationPort, 49152);
    });

    test('ACK transitions to established', () {
      final syn = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1000,
        ackNum: 0,
        flags: TcpFlags.syn,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      session.buildSynAck(syn);

      final ack = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1001,
        ackNum: session.buildSynAck(syn).seqNum + 1,
        flags: TcpFlags.ack,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      session.handlePacket(ack);

      expect(session.state, TcpState.established);
    });

    test('data packet forwards to handle and returns ACK', () {
      _completeHandshake(session);

      final data = Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F]);
      final dataPkt = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1001,
        ackNum: 0,
        flags: TcpFlags.ack | TcpFlags.psh,
        windowSize: 65535,
        payload: data,
      );
      final replies = session.handlePacket(dataPkt);

      expect(replies, hasLength(1));
      expect(replies.first.isAck, isTrue);
      expect(handle.sentData, data);
    });

    test('FIN closes session and returns ACK', () {
      _completeHandshake(session);

      final fin = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1001,
        ackNum: 0,
        flags: TcpFlags.fin | TcpFlags.ack,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      final replies = session.handlePacket(fin);

      expect(replies, hasLength(1));
      expect(replies.first.isAck, isTrue);
      expect(session.isClosed, isTrue);
      expect(handle.closed, isTrue);
    });

    test('buildDataPackets segments at MSS', () {
      _completeHandshake(session);

      final largeData = Uint8List(3000);
      final packets = session.buildDataPackets(largeData);

      expect(packets.length, 3);
      expect(packets[0].payload.length, 1460);
      expect(packets[1].payload.length, 1460);
      expect(packets[2].payload.length, 80);

      var totalPayload = 0;
      for (final pkt in packets) {
        totalPayload += pkt.payload.length;
        expect(pkt.isAck, isTrue);
        expect(pkt.isPsh, isTrue);
      }
      expect(totalPayload, 3000);
    });

    test('buildFinPacket transitions to finWait', () {
      _completeHandshake(session);

      final fin = session.buildFinPacket();
      expect(fin.isFin, isTrue);
      expect(fin.isAck, isTrue);
      expect(session.state, TcpState.finWait);
    });

    test('finWait ACK closes session', () {
      _completeHandshake(session);
      session.buildFinPacket();

      final ack = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1001,
        ackNum: 0,
        flags: TcpFlags.ack,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      session.handlePacket(ack);

      expect(session.isClosed, isTrue);
    });

    test('finWait FIN closes session with ACK', () {
      _completeHandshake(session);
      session.buildFinPacket();

      final fin = TcpPacket(
        sourcePort: 49152,
        destinationPort: 80,
        seqNum: 1001,
        ackNum: 0,
        flags: TcpFlags.fin | TcpFlags.ack,
        windowSize: 65535,
        payload: Uint8List(0),
      );
      final replies = session.handlePacket(fin);

      expect(replies, hasLength(1));
      expect(replies.first.isAck, isTrue);
      expect(session.isClosed, isTrue);
    });
  });
}

void _completeHandshake(TcpSession session) {
  final syn = TcpPacket(
    sourcePort: 49152,
    destinationPort: 80,
    seqNum: 1000,
    ackNum: 0,
    flags: TcpFlags.syn,
    windowSize: 65535,
    payload: Uint8List(0),
  );
  session.buildSynAck(syn);

  final ack = TcpPacket(
    sourcePort: 49152,
    destinationPort: 80,
    seqNum: 1001,
    ackNum: 0,
    flags: TcpFlags.ack,
    windowSize: 65535,
    payload: Uint8List(0),
  );
  session.handlePacket(ack);
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
