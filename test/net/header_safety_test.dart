@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/net/http_proxy.dart';
import 'package:test/test.dart';

/// An HTTP header carries bytes, so a value with a character above U+00FF has
/// no representation in one and `fetch` refuses the whole request — with a
/// TypeError that names neither the header nor the value. A key pasted from a
/// rendered page can pick up such a character while looking identical to a
/// clean one, so the proxy checks before handing anything to the browser.
///
/// The awkward characters are written as escapes on purpose: as literals they
/// would be invisible here too, which is the whole problem.
void main() {
  Upstream openRouter() => Upstream(
    host: 'llm.local',
    target: Uri.parse('https://openrouter.ai/api'),
    injectHeaders: const {'authorization': r'Bearer ${KEY}'},
  );

  GuestRequest guestRequest({String? body}) {
    final payload = body ?? '{"model":"m","messages":[]}';
    final payloadBytes = utf8.encode(payload);
    final head =
        'POST /v1/chat/completions HTTP/1.1\r\n'
        'Host: llm.local\r\n'
        'Authorization: Bearer \${KEY}\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${payloadBytes.length}\r\n'
        'Connection: close\r\n\r\n';
    final parser = GuestRequestParser()
      ..add(Uint8List.fromList([...latin1.encode(head), ...payloadBytes]));
    return parser.take()!;
  }

  HttpProxy proxyWith(String key) => HttpProxy(
    upstreams: [openRouter()],
    credentials: CredentialStore({'KEY': key}),
    transport: (request) async => throw StateError('should not be sent'),
  );

  // The agent's own system prompt contains an em dash, so a UTF-8 body
  // reaching the proxy is the ordinary case rather than an edge one. It must
  // not make the headers unsendable.
  test('a UTF-8 body leaves the headers sendable', () {
    final outbound = proxyWith('sk-or-v1-abc').resolve(
      guestRequest(
        body:
            '{"model":"m","messages":[{"role":"system",'
            '"content":"no browser \u{2014} use the shell"}]}',
      ),
    );

    for (final entry in outbound.headers.entries) {
      for (var i = 0; i < entry.value.length; i++) {
        expect(
          entry.value.codeUnitAt(i),
          lessThanOrEqualTo(0xFF),
          reason: 'header "${entry.key}" must be byte-representable',
        );
      }
    }
    expect(utf8.decode(outbound.body), contains('\u{2014}'));
  });

  test('a credential with a hidden character is refused by name', () {
    const tainted = <String, String>{
      'zero-width space': 'sk-or-v1\u{200B}abc',
      'em dash': 'sk-or-v1\u{2014}abc',
      'ideographic space': 'sk-or-v1\u{3000}abc',
      'control character': 'sk-or-v1\u{0001}abc',
    };

    for (final entry in tainted.entries) {
      final description = entry.key;
      final key = entry.value;
      expect(
        () => proxyWith(key).resolve(guestRequest()),
        throwsA(
          isA<ProxyRefusal>().having(
            (refusal) => refusal.message,
            'message',
            allOf(contains('authorization'), contains('cannot be sent')),
          ),
        ),
        reason: 'should refuse a key carrying a $description',
      );
    }
  });

  test('an ordinary key is sent unchanged', () {
    final outbound = proxyWith('sk-or-v1-62d0b4aa').resolve(guestRequest());
    expect(outbound.headers['authorization'], 'Bearer sk-or-v1-62d0b4aa');
  });

  test('the refusal reaches the guest as something it can read', () async {
    final rendered = latin1.decode(
      await proxyWith('sk-or-v1\u{200B}abc').handle(guestRequest()),
    );
    expect(rendered, startsWith('HTTP/1.1 401'));
    expect(rendered, contains('cannot be sent in an HTTP header'));
    expect(rendered, contains('U+200B'));
  });
}
