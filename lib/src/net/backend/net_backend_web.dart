import 'dart:async';
import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';
import 'package:dart_emu/src/net/http_proxy.dart';
import 'package:dart_emu/src/net/web_fetch.dart';

/// Creates the default [NetBackend] for the web platform.
NetBackend createDefaultNetBackend() => WebNetBackend();

class _Web {
  /// Guests speak plain HTTP; the host adds the TLS on the way out.
  static const proxyPort = 80;

  /// Loopback, handed back for every allowed name. The guest only needs an
  /// address to open a socket to; the host routes on the Host header.
  static final loopback = Uint8List.fromList([127, 0, 0, 1]);
}

/// Web network backend.
///
/// A browser cannot open raw TCP or UDP sockets, so nothing the guest does
/// reaches the network directly. What it can do is speak plain HTTP to a
/// configured upstream, which this backend reissues with `fetch`.
///
/// That is narrower than a real network, deliberately: the reachable
/// destinations are exactly the configured upstreams, and credentials are
/// attached here rather than being given to the guest.
class WebNetBackend implements NetBackend {
  WebNetBackend({
    List<Upstream> upstreams = const [],
    CredentialStore? credentials,
    ProxyTransport? transport,
  }) : _proxy = HttpProxy(
         upstreams: upstreams,
         credentials: credentials ?? CredentialStore(),
         transport: transport ?? fetchTransport,
       );

  final HttpProxy _proxy;
  final List<_ProxiedConnection> _connections = [];

  /// Credentials held here, never handed to the guest.
  CredentialStore get credentials => _proxy.credentials;

  @override
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort) {
    if (destPort != _Web.proxyPort) {
      // Anything else would need a real socket. Refusing produces an RST,
      // which the guest reports as connection refused.
      return null;
    }
    final connection = _ProxiedConnection(_proxy);
    _connections.add(connection);
    return connection;
  }

  @override
  void sendUdpDatagram(
    Uint8List destIp,
    int destPort,
    Uint8List data,
    DataCallback onResponse,
  ) {
    // No raw UDP in a browser, and nothing here needs it.
  }

  @override
  List<Uint8List>? resolveDns(String hostname) {
    // Configured upstreams resolve to loopback: the guest needs an address
    // to connect to, and the routing happens on the Host header.
    return _proxy.allows(hostname) ? [_Web.loopback] : null;
  }

  @override
  void poll() {
    _connections.removeWhere((connection) => connection.isFinished);
  }

  @override
  void dispose() {
    for (final connection in _connections) {
      connection.close();
    }
    _connections.clear();
  }
}

/// One guest connection, carrying a request out and a response back.
class _ProxiedConnection implements TcpConnectionHandle {
  _ProxiedConnection(this._proxy);

  final HttpProxy _proxy;
  final GuestRequestParser _parser = GuestRequestParser();
  final List<int> _inbound = [];

  bool _closed = false;
  bool _responseComplete = false;
  bool _inFlight = false;

  bool get isFinished => _closed && _inbound.isEmpty;

  @override
  bool get isConnected => !_closed;

  @override
  bool get hasData => _inbound.isNotEmpty;

  /// The guest is told the peer closed once the response has been read,
  /// which is what stops a `Connection: close` client waiting for more.
  @override
  bool get isRemoteClosed => _responseComplete && _inbound.isEmpty;

  @override
  void send(Uint8List data) {
    if (_closed) {
      return;
    }
    _parser.add(data);
    final request = _parser.take();
    if (request == null || _inFlight) {
      return;
    }
    _inFlight = true;
    unawaited(_dispatch(request));
  }

  Future<void> _dispatch(GuestRequest request) async {
    final rendered = await _proxy.handle(request);
    if (_closed) {
      return;
    }
    _inbound.addAll(rendered);
    _responseComplete = true;
    _inFlight = false;
  }

  @override
  Uint8List? receive() {
    if (_inbound.isEmpty) {
      return null;
    }
    final data = Uint8List.fromList(_inbound);
    _inbound.clear();
    return data;
  }

  @override
  void close() {
    _closed = true;
  }
}
