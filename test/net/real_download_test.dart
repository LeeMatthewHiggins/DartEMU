@TestOn('vm')
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/ipv4_packet.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:dart_emu/src/net/tcp_packet.dart';
import 'package:dart_emu/src/net/user_net_device.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _gistRawUrl =
    'https://gist.githubusercontent.com'
    '/khaykov/a6105154becce4c0530da38e723c2330/raw/';
const _pollDelay = Duration(milliseconds: 20);

void main() {
  late HttpServer server;
  late int serverPort;
  late Uint8List expectedBody;

  setUp(() async {
    // Fetch the 1MB text file from the public gist.
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(_gistRawUrl));
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    expectedBody = builder.toBytes();
    client.close();

    // Serve it on a local HTTP server.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverPort = server.port;
    server.listen((req) {
      req.response
        ..headers.contentLength = expectedBody.length
        ..add(expectedBody);
      unawaited(req.response.close());
    });
  });

  tearDown(() async {
    await server.close();
  });

  test(
    'downloads 1MB gist file via local HTTP server',
    () async {
      final device = UserNetDevice();
      final mac = UserNetMac.defaultClient;
      final clientIp = UserNetAddr.dhcpClient;
      final serverIp = Uint8List.fromList([127, 0, 0, 1]);

      // ARP + DHCP (local, instant).
      device
        ..writePacket(
          buildArpRequest(
            senderMac: mac,
            senderIp: clientIp,
            targetIp: UserNetAddr.gateway,
          ),
        )
        ..readPacket()
        ..writePacket(buildDhcpDiscover(clientMac: mac))
        ..readPacket()
        ..writePacket(
          buildDhcpRequest(
            clientMac: mac,
            requestedIp: clientIp,
            serverIp: UserNetAddr.gateway,
          ),
        )
        ..readPacket();

      // TCP handshake to 127.0.0.1:serverPort.
      const srcPort = 50000;
      const initialSeq = 2000;
      var guestSeq = initialSeq;

      device.writePacket(
        buildTcpSyn(
          srcIp: clientIp,
          srcMac: mac,
          dstIp: serverIp,
          dstPort: serverPort,
          srcPort: srcPort,
          seqNum: initialSeq,
        ),
      );
      guestSeq++;

      final synAck = await _waitForTcp(device, (tcp) => tcp.isSyn && tcp.isAck);
      expect(synAck, isNotNull, reason: 'No SYN-ACK');
      var serverSeq = synAck!.seqNum + 1;

      // Complete handshake.
      device.writePacket(
        buildTcpPacket(
          srcIp: clientIp,
          srcMac: mac,
          dstIp: serverIp,
          dstPort: serverPort,
          srcPort: srcPort,
          seqNum: guestSeq,
          ackNum: serverSeq,
          flags: TcpFlags.ack,
        ),
      );

      // Let localhost socket connect.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(_pollDelay);
        device.poll();
        _drainPackets(device);
      }

      // Send HTTP GET.
      final httpReq = Uint8List.fromList(
        'GET / HTTP/1.0\r\n'
                'Host: localhost\r\n'
                '\r\n'
            .codeUnits,
      );
      device.writePacket(
        buildTcpPacket(
          srcIp: clientIp,
          srcMac: mac,
          dstIp: serverIp,
          dstPort: serverPort,
          srcPort: srcPort,
          seqNum: guestSeq,
          ackNum: serverSeq,
          flags: TcpFlags.ack | TcpFlags.psh,
          payload: httpReq,
        ),
      );
      guestSeq += httpReq.length;

      // Receive all data until FIN or timeout.
      final received = BytesBuilder(copy: false);
      var done = false;
      var idleCount = 0;
      const maxIdle = 500;

      while (!done && idleCount < maxIdle) {
        await Future<void>.delayed(_pollDelay);
        device.poll();

        var gotData = false;
        for (
          var raw = device.readPacket();
          raw != null;
          raw = device.readPacket()
        ) {
          final tcp = _parseTcp(raw);
          if (tcp == null) continue;

          if (tcp.payload.isNotEmpty) {
            received.add(tcp.payload);
            serverSeq += tcp.payload.length;
            gotData = true;
          }
          if (tcp.isFin) {
            serverSeq++;
            done = true;
          }
          if (tcp.payload.isNotEmpty || tcp.isFin) {
            device.writePacket(
              buildTcpPacket(
                srcIp: clientIp,
                srcMac: mac,
                dstIp: serverIp,
                dstPort: serverPort,
                srcPort: srcPort,
                seqNum: guestSeq,
                ackNum: serverSeq,
                flags: TcpFlags.ack,
              ),
            );
          }
        }
        idleCount = gotData ? 0 : idleCount + 1;
      }

      expect(done, isTrue, reason: 'Never received FIN');

      // Parse HTTP response: split headers from body.
      final allBytes = received.toBytes();
      final headerEnd = _findHeaderEnd(allBytes);
      expect(headerEnd, isNonNegative, reason: 'No HTTP header boundary found');
      final body = Uint8List.sublistView(allBytes, headerEnd);

      expect(
        body.length,
        expectedBody.length,
        reason:
            'Body is ${body.length} bytes, '
            'expected ${expectedBody.length}',
      );
      expect(body, expectedBody);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<TcpPacket?> _waitForTcp(
  UserNetDevice device,
  bool Function(TcpPacket) predicate,
) async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(_pollDelay);
    device.poll();
    final raw = device.readPacket();
    if (raw == null) continue;
    final tcp = _parseTcp(raw);
    if (tcp != null && predicate(tcp)) return tcp;
  }
  return null;
}

void _drainPackets(UserNetDevice device) {
  while (device.readPacket() != null) {}
}

TcpPacket? _parseTcp(Uint8List raw) {
  final frame = EthernetFrame.parse(raw);
  if (frame == null) return null;
  final ip = Ipv4Packet.parse(frame.payload);
  if (ip == null || ip.protocol != IpProtocol.tcp) {
    return null;
  }
  return TcpPacket.parse(ip.payload);
}

int _findHeaderEnd(Uint8List data) {
  const separator = [0x0D, 0x0A, 0x0D, 0x0A];
  for (var i = 0; i <= data.length - 4; i++) {
    if (data[i] == separator[0] &&
        data[i + 1] == separator[1] &&
        data[i + 2] == separator[2] &&
        data[i + 3] == separator[3]) {
      return i + 4;
    }
  }
  return -1;
}
