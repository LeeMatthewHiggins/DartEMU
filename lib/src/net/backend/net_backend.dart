import 'dart:typed_data';

export 'net_backend_native.dart'
    if (dart.library.js_interop) 'net_backend_web.dart';

/// Callback for receiving data from an async operation.
typedef DataCallback = void Function(Uint8List data);

/// Abstract interface for outbound network connectivity.
///
/// Native platforms use real TCP/UDP sockets. Web platforms
/// support only HTTP-based connections via the fetch API.
abstract class NetBackend {
  /// Opens a TCP connection to the given IP and port.
  ///
  /// Returns a handle for sending/receiving, or `null` if the
  /// connection cannot be established (triggers RST on the guest).
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort);

  /// Sends a UDP datagram and registers a callback for responses.
  void sendUdpDatagram(
    Uint8List destIp,
    int destPort,
    Uint8List data,
    DataCallback onResponse,
  );

  /// Resolves a hostname to IPv4 addresses.
  ///
  /// Returns `null` if the lookup is still pending or failed.
  List<Uint8List>? resolveDns(String hostname);

  /// Drains completed async operations into synchronous buffers.
  ///
  /// Called once per emulator step from the synchronous polling loop.
  void poll();

  /// Releases all resources.
  void dispose();
}

/// Handle for a single TCP connection.
abstract class TcpConnectionHandle {
  /// Sends data to the remote end.
  void send(Uint8List data);

  /// Reads available data, or `null` if nothing is buffered.
  Uint8List? receive();

  /// Whether the connection is established.
  bool get isConnected;

  /// Whether there is buffered inbound data.
  bool get hasData;

  /// Whether the remote end has closed the connection.
  bool get isRemoteClosed;

  /// Closes the connection.
  void close();
}
