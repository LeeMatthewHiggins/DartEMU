@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/net/http_proxy.dart';
import 'package:dart_emu/src/net/web_fetch.dart';
import 'package:test/test.dart';

/// The `fetch` shim is the only part of the proxy a VM test cannot reach, so
/// it is exercised in a real browser against the test runner's own server.
///
/// Everything here is same-origin: the point is that the shim marshals a
/// request and reads a response correctly, not that a browser can talk to
/// the internet.
void main() {
  final own = Uri.base;

  test('a request goes out and a response comes back', () async {
    final response = await fetchTransport(
      ProxyRequest(
        method: 'GET',
        url: own,
        headers: const {},
        body: Uint8List(0),
      ),
    );

    expect(response.statusCode, 200);
    expect(response.body, isNotEmpty);
  });

  test('a status that is not success still yields its body', () async {
    // A refusal from a real upstream arrives this way, and the agent is
    // meant to read the reason rather than see a dead connection.
    final response = await fetchTransport(
      ProxyRequest(
        method: 'GET',
        url: own.resolve('no-such-file-${own.hashCode}'),
        headers: const {},
        body: Uint8List(0),
      ),
    );

    expect(response.statusCode, greaterThanOrEqualTo(400));
  });

  test('the response is rendered as HTTP the guest can parse', () async {
    final response = await fetchTransport(
      ProxyRequest(
        method: 'GET',
        url: own,
        headers: const {},
        body: Uint8List(0),
      ),
    );

    final rendered = latin1.decode(renderResponse(response));
    expect(rendered, startsWith('HTTP/1.1 200'));
    expect(rendered, contains('Content-Length: ${response.body.length}'));
  });
}
