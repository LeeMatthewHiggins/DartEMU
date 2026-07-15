import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/net/backend/net_backend.dart';

/// Creates the default [NetBackend] for the current platform.
NetBackend createDefaultNetBackend() => NativeNetBackend();

/// Native network backend using dart:io sockets.
class NativeNetBackend implements NetBackend {
  final Map<int, NativeTcpConnection> _tcpConnections = {};
  final Map<String, List<Uint8List>> _dnsCache = {};
  final Map<String, bool> _dnsPending = {};
  int _nextId = 0;

  @override
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort) {
    final ipStr = destIp.join('.');
    final connection = NativeTcpConnection._(id: _nextId++);
    _tcpConnections[connection._id] = connection;
    Socket.connect(
      ipStr,
      destPort,
    ).then(connection._onConnected, onError: connection._onError);
    return connection;
  }

  @override
  void sendUdpDatagram(
    Uint8List destIp,
    int destPort,
    Uint8List data,
    DataCallback onResponse,
  ) {
    final ipStr = destIp.join('.');
    RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((socket) {
      socket
        ..send(data, InternetAddress(ipStr), destPort)
        ..listen((event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket.receive();
            if (datagram != null) {
              onResponse(datagram.data);
              socket.close();
            }
          }
        }, onDone: socket.close);
      // Auto-close after timeout.
      Future<void>.delayed(const Duration(seconds: 5), socket.close);
    }, onError: (_) {});
  }

  @override
  List<Uint8List>? resolveDns(String hostname) {
    final cached = _dnsCache[hostname];
    if (cached != null) return cached;
    if (_dnsPending[hostname] ?? false) return null;
    _dnsPending[hostname] = true;
    InternetAddress.lookup(hostname).then(
      (addresses) {
        _dnsCache[hostname] = addresses
            .where((a) => a.type == InternetAddressType.IPv4)
            .map((a) => Uint8List.fromList(a.rawAddress))
            .toList();
        _dnsPending.remove(hostname);
      },
      onError: (_) {
        _dnsPending.remove(hostname);
      },
    );
    return null;
  }

  @override
  void poll() {
    // Async callbacks fire between step() invocations during the
    // await Future.delayed() in the emulator loop. No explicit
    // draining is needed — data arrives via Socket.listen callbacks.
  }

  @override
  void dispose() {
    for (final conn in _tcpConnections.values) {
      conn.close();
    }
    _tcpConnections.clear();
  }
}

/// A single TCP connection managed via dart:io [Socket].
class NativeTcpConnection implements TcpConnectionHandle {
  NativeTcpConnection._({required int id}) : _id = id;

  final int _id;
  Socket? _socket;
  bool _connected = false;
  bool _remoteClosed = false;
  bool _closed = false;
  final List<Uint8List> _receiveBuffer = [];
  final List<Uint8List> _sendBuffer = [];

  void _onConnected(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    _socket = socket;
    _connected = true;
    socket.listen(
      (data) => _receiveBuffer.add(Uint8List.fromList(data)),
      onDone: () => _remoteClosed = true,
      onError: (_) => _remoteClosed = true,
    );
    _flushSendBuffer();
  }

  void _onError(Object error) {
    _remoteClosed = true;
  }

  @override
  void send(Uint8List data) {
    final socket = _socket;
    if (socket != null) {
      socket.add(data);
    } else if (!_closed && !_remoteClosed) {
      _sendBuffer.add(data);
    }
  }

  void _flushSendBuffer() {
    final socket = _socket;
    if (socket == null) return;
    for (final data in _sendBuffer) {
      socket.add(data);
    }
    _sendBuffer.clear();
  }

  @override
  Uint8List? receive() {
    if (_receiveBuffer.isEmpty) return null;
    if (_receiveBuffer.length == 1) return _receiveBuffer.removeAt(0);
    final totalLength = _receiveBuffer.fold<int>(
      0,
      (sum, chunk) => sum + chunk.length,
    );
    final merged = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in _receiveBuffer) {
      merged.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _receiveBuffer.clear();
    return merged;
  }

  @override
  bool get isConnected => _connected;

  @override
  bool get hasData => _receiveBuffer.isNotEmpty;

  @override
  bool get isRemoteClosed => _remoteClosed;

  @override
  void close() {
    _closed = true;
    _socket?.destroy();
    _socket = null;
  }
}
