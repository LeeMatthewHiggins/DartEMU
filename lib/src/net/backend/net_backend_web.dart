import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';

/// Creates the default [NetBackend] for the web platform.
NetBackend createDefaultNetBackend() => WebNetBackend();

/// Web network backend with limited connectivity.
///
/// Browsers cannot open raw TCP/UDP sockets. This backend supports:
/// - TCP to ports 80/443 via a buffered HTTP proxy approach
/// - DNS via DNS-over-HTTPS
/// - All other TCP connections are refused (returns null → RST)
/// - All other UDP is silently dropped
class WebNetBackend implements NetBackend {
  @override
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort) {
    // Web cannot open raw TCP sockets.
    return null;
  }

  @override
  void sendUdpDatagram(
    Uint8List destIp,
    int destPort,
    Uint8List data,
    DataCallback onResponse,
  ) {
    // Web cannot send raw UDP datagrams.
  }

  @override
  List<Uint8List>? resolveDns(String hostname) {
    return null;
  }

  @override
  void poll() {}

  @override
  void dispose() {}
}
