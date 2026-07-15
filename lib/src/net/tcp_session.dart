import 'dart:math';
import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';

/// Builds a string key for a TCP four-tuple.
String tcpSessionKeyOf(
  Uint8List remoteIp,
  int remotePort,
  Uint8List localIp,
  int localPort,
) {
  return '${remoteIp.join(".")}:$remotePort-'
      '${localIp.join(".")}:$localPort';
}

/// States for a simplified TCP connection proxy.
enum TcpState { synReceived, established, finWait, closed }

/// Manages TCP state for a single proxied connection.
///
/// This is a simplified proxy — the guest kernel handles real TCP
/// reliability. We just need to relay data between the guest's
/// TCP stack and the host socket, maintaining correct seq/ack.
class TcpSession {
  TcpSession({
    required this.handle,
    required this.remoteIp,
    required this.remotePort,
    required this.localPort,
    required int initialGuestSeq,
  }) : _hostSeq = Random().nextInt(0xFFFFFFFF),
       _guestAcked = initialGuestSeq + 1;

  final TcpConnectionHandle handle;
  final Uint8List remoteIp;
  final int remotePort;
  final int localPort;
  TcpState state = TcpState.synReceived;

  int _hostSeq;
  int _guestAcked;

  bool get isClosed => state == TcpState.closed;

  /// Processes an incoming TCP packet from the guest.
  List<TcpPacket> handlePacket(TcpPacket packet) {
    return switch (state) {
      TcpState.synReceived => _handleSynReceived(packet),
      TcpState.established => _handleEstablished(packet),
      TcpState.finWait => _handleFinWait(packet),
      TcpState.closed => [],
    };
  }

  /// Builds data packets for data received from the host socket.
  List<TcpPacket> buildDataPackets(Uint8List data) {
    final packets = <TcpPacket>[];
    var offset = 0;
    while (offset < data.length) {
      final chunkSize = min(data.length - offset, _maxSegmentSize);
      packets.add(
        TcpPacket(
          sourcePort: remotePort,
          destinationPort: localPort,
          seqNum: _hostSeq & _seqMask,
          ackNum: _guestAcked & _seqMask,
          flags: TcpFlags.ack | TcpFlags.psh,
          windowSize: _windowSize,
          payload: Uint8List.sublistView(data, offset, offset + chunkSize),
        ),
      );
      _hostSeq += chunkSize;
      offset += chunkSize;
    }
    return packets;
  }

  /// Builds a FIN packet when the host socket closes.
  TcpPacket buildFinPacket() {
    state = TcpState.finWait;
    final fin = TcpPacket(
      sourcePort: remotePort,
      destinationPort: localPort,
      seqNum: _hostSeq & _seqMask,
      ackNum: _guestAcked & _seqMask,
      flags: TcpFlags.fin | TcpFlags.ack,
      windowSize: _windowSize,
      payload: Uint8List(0),
    );
    _hostSeq++;
    return fin;
  }

  /// Returns the SYN-ACK packet for the initial handshake.
  TcpPacket buildSynAck(TcpPacket syn) {
    _guestAcked = (syn.seqNum + 1) & _seqMask;
    final synAck = TcpPacket(
      sourcePort: remotePort,
      destinationPort: localPort,
      seqNum: _hostSeq & _seqMask,
      ackNum: _guestAcked & _seqMask,
      flags: TcpFlags.syn | TcpFlags.ack,
      windowSize: _windowSize,
      payload: Uint8List(0),
    );
    _hostSeq++;
    return synAck;
  }

  List<TcpPacket> _handleSynReceived(TcpPacket packet) {
    if (packet.isAck) {
      state = TcpState.established;
    }
    return [];
  }

  List<TcpPacket> _handleEstablished(TcpPacket packet) {
    final results = <TcpPacket>[];

    if (packet.payload.isNotEmpty) {
      handle.send(packet.payload);
      _guestAcked += packet.payload.length;
      results.add(_buildAck());
    }

    if (packet.isFin) {
      _guestAcked++;
      handle.close();
      state = TcpState.closed;
      results.add(_buildAck());
    }

    return results;
  }

  List<TcpPacket> _handleFinWait(TcpPacket packet) {
    if (packet.isFin) {
      _guestAcked++;
      state = TcpState.closed;
      return [_buildAck()];
    }
    if (packet.isAck) {
      state = TcpState.closed;
    }
    return [];
  }

  TcpPacket _buildAck() {
    return TcpPacket(
      sourcePort: remotePort,
      destinationPort: localPort,
      seqNum: _hostSeq & _seqMask,
      ackNum: _guestAcked & _seqMask,
      flags: TcpFlags.ack,
      windowSize: _windowSize,
      payload: Uint8List(0),
    );
  }

  static const _maxSegmentSize = 1460;
  static const _windowSize = 65535;
  static const _seqMask = 0xFFFFFFFF;
}
