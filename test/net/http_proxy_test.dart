@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/net/http_proxy.dart';
import 'package:test/test.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Builds a raw HTTP/1.1 request the way a guest's client would write it.
Uint8List rawRequest({
  String method = 'POST',
  String path = '/v1/chat/completions',
  String host = 'llm.local',
  String body = '{"model":"x"}',
  Map<String, String> headers = const {},
}) {
  final head = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: $host\r\n')
    ..write('Authorization: Bearer \${OPENROUTER_KEY}\r\n');
  headers.forEach((k, v) => head.write('$k: $v\r\n'));
  head
    ..write('Content-Length: ${body.length}\r\n')
    ..write('\r\n')
    ..write(body);
  return bytes(head.toString());
}

GuestRequest parse(Uint8List raw) {
  final parser = GuestRequestParser()..add(raw);
  return parser.take()!;
}

HttpProxy proxyWith({
  Map<String, String> credentials = const {'OPENROUTER_KEY': 'sk-real-secret'},
  ProxyTransport? transport,
  List<Upstream>? upstreams,
}) => HttpProxy(
  upstreams:
      upstreams ??
      [
        Upstream(
          host: 'llm.local',
          target: Uri.parse('https://openrouter.ai/api'),
          injectHeaders: const {
            'authorization': r'Bearer ${OPENROUTER_KEY}',
          },
        ),
      ],
  credentials: CredentialStore({...credentials}),
  transport:
      transport ??
      (request) async => ProxyResponse(
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        body: bytes('{"ok":true}'),
      ),
);

void main() {
  group('parsing what the guest wrote', () {
    test('a complete request is read once the body has arrived', () {
      final request = parse(rawRequest());
      expect(request.method, 'POST');
      expect(request.path, '/v1/chat/completions');
      expect(request.host, 'llm.local');
      expect(utf8.decode(request.body), '{"model":"x"}');
    });

    test('a request split across writes is not read early', () {
      final whole = rawRequest();
      final parser = GuestRequestParser()
        ..add(Uint8List.sublistView(whole, 0, 30));
      expect(parser.take(), isNull, reason: 'headers are incomplete');

      parser.add(Uint8List.sublistView(whole, 30, whole.length - 5));
      expect(parser.take(), isNull, reason: 'the body is still arriving');

      parser.add(Uint8List.sublistView(whole, whole.length - 5));
      expect(parser.take(), isNotNull, reason: 'now it is complete');
    });
  });

  group('credentials never reach the guest', () {
    test(
      'the placeholder is replaced with the real key on the way out',
      () async {
        ProxyRequest? sent;
        final proxy = proxyWith(
          transport: (request) async {
            sent = request;
            return ProxyResponse(
              statusCode: 200,
              headers: const {},
              body: bytes('{}'),
            );
          },
        );
        await proxy.handle(parse(rawRequest()));

        expect(sent!.headers['authorization'], 'Bearer sk-real-secret');
        expect(sent!.url.toString(), contains('openrouter.ai'));
      },
    );

    test('the guest only ever writes a placeholder', () {
      // The name is what the guest carries. A fully compromised guest
      // yields this string and nothing else.
      final request = parse(rawRequest());
      expect(request.headers['authorization'], r'Bearer ${OPENROUTER_KEY}');
      expect(request.headers['authorization'], isNot(contains('sk-')));
    });

    test('a missing credential is explained, not silently dropped', () async {
      final proxy = proxyWith(credentials: const {});
      final raw = await proxy.handle(parse(rawRequest()));
      final text = utf8.decode(raw);

      expect(text, startsWith('HTTP/1.1 401'));
      expect(
        text,
        contains('OPENROUTER_KEY'),
        reason: 'the agent is told which credential is wanted',
      );
      expect(text, contains('Enter a key on the page'));
    });

    test('a refusal is valid JSON an API client can read', () async {
      final proxy = proxyWith(credentials: const {});
      final raw = utf8.decode(await proxy.handle(parse(rawRequest())));
      final body = raw.substring(raw.indexOf('\r\n\r\n') + 4);
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect((decoded['error'] as Map)['message'], contains('OPENROUTER_KEY'));
    });
  });

  group('only configured upstreams are reachable', () {
    test('an unknown host is refused with a readable reason', () async {
      final proxy = proxyWith();
      final raw = await proxy.handle(parse(rawRequest(host: 'evil.example')));
      final text = utf8.decode(raw);
      expect(text, startsWith('HTTP/1.1 502'));
      expect(text, contains('evil.example'));
    });

    test('an unknown host never reaches the transport', () async {
      var called = false;
      final proxy = proxyWith(
        transport: (request) async {
          called = true;
          return ProxyResponse(
            statusCode: 200,
            headers: const {},
            body: Uint8List(0),
          );
        },
      );
      await proxy.handle(parse(rawRequest(host: 'evil.example')));
      expect(called, isFalse, reason: 'policy is applied before the request');
    });

    test('allows() reports what DNS should resolve', () {
      final proxy = proxyWith();
      expect(proxy.allows('llm.local'), isTrue);
      expect(proxy.allows('llm.local:80'), isTrue, reason: 'a port is ignored');
      expect(proxy.allows('evil.example'), isFalse);
      expect(proxy.allows(null), isFalse);
    });
  });

  group('the response the guest reads', () {
    test('carries the status, body and a correct length', () async {
      final proxy = proxyWith(
        transport: (request) async => ProxyResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          body: bytes('{"choices":[]}'),
        ),
      );
      final text = utf8.decode(await proxy.handle(parse(rawRequest())));

      expect(text, startsWith('HTTP/1.1 200 OK'));
      expect(text, contains('Content-Length: 14'));
      expect(text, endsWith('{"choices":[]}'));
    });

    test('an upstream error is passed through, not hidden', () async {
      final proxy = proxyWith(
        transport: (request) async => ProxyResponse(
          statusCode: 429,
          headers: const {},
          body: bytes('slow down'),
        ),
      );
      final text = utf8.decode(await proxy.handle(parse(rawRequest())));
      expect(text, startsWith('HTTP/1.1 429'));
      expect(text, endsWith('slow down'));
    });

    test('a transport failure becomes a readable response', () async {
      final proxy = proxyWith(
        transport: (request) async => throw StateError('network is down'),
      );
      final text = utf8.decode(await proxy.handle(parse(rawRequest())));
      expect(text, startsWith('HTTP/1.1 502'));
      expect(text, contains('network is down'));
    });

    test('the host framing headers are rewritten, not echoed', () async {
      final proxy = proxyWith(
        transport: (request) async => ProxyResponse(
          statusCode: 200,
          // An upstream length that disagrees with the body would desync
          // the guest's parser if it were passed through.
          headers: const {
            'content-length': '9999',
            'transfer-encoding': 'chunked',
          },
          body: bytes('short'),
        ),
      );
      final text = utf8.decode(await proxy.handle(parse(rawRequest())));
      expect(text, contains('Content-Length: 5'));
      expect(text, isNot(contains('9999')));
      expect(text.toLowerCase(), isNot(contains('chunked')));
    });
  });
}
