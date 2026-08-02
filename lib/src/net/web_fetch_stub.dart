import 'package:dart_emu/src/net/http_proxy.dart';

/// Stand-in for the browser transport on platforms that have no `fetch`.
///
/// The web backend is only reachable on web, but its routing and policy are
/// worth testing on the VM, so the transport is swapped rather than making
/// the whole file unloadable.
Future<ProxyResponse> fetchTransport(ProxyRequest request) =>
    throw UnsupportedError('fetch is only available in a browser');
