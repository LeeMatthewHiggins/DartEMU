/// Host-side HTTP proxy for guests that cannot open raw sockets.
///
/// A browser has no TCP, only `fetch`, and `fetch` owns the TLS. A guest
/// therefore cannot speak HTTPS through it. Instead the guest speaks plain
/// HTTP to a named upstream, and the host reissues the request to the real
/// endpoint over TLS.
///
/// The arrangement is what makes credential injection safe. The guest is
/// built with a placeholder naming the credential it wants, never the
/// credential itself, so a guest that is completely compromised yields a
/// name. There is no field in the image capable of holding a secret.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Matches `${NAME}` in a configured header value.
final RegExp _placeholder = RegExp(r'\$\{([A-Za-z0-9_]+)\}');

class _Http {
  static const version = 'HTTP/1.1';
  static const headerEnd = '\r\n\r\n';
  static const lineEnd = '\r\n';
  static const badGateway = 502;
  static const credentialMissing = 401;
}

/// A named destination the guest is allowed to reach.
class Upstream {
  const Upstream({
    required this.host,
    required this.target,
    this.injectHeaders = const {},
  });

  /// Host name the guest uses, as it appears in the `Host` header.
  final String host;

  /// Where the request is actually sent, over TLS.
  final Uri target;

  /// Headers added to every request. Values may contain `${NAME}`
  /// placeholders, resolved against the host's credentials.
  final Map<String, String> injectHeaders;
}

/// Credentials held on the host and never given to the guest.
class CredentialStore {
  CredentialStore([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  /// Sets or replaces a credential. Passing null removes it.
  void set(String name, String? value) {
    if (value == null || value.isEmpty) {
      _values.remove(name);
    } else {
      _values[name] = value;
    }
  }

  bool has(String name) => _values.containsKey(name);

  String? operator [](String name) => _values[name];
}

/// A request the host should make on the guest's behalf.
class ProxyRequest {
  const ProxyRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Uint8List body;
}

/// What came back, ready to be rendered for the guest.
class ProxyResponse {
  const ProxyResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
}

/// Performs the outbound request. Supplied by the platform: `fetch` on web,
/// a fake in tests.
typedef ProxyTransport = Future<ProxyResponse> Function(ProxyRequest request);

/// One HTTP request as the guest wrote it.
class GuestRequest {
  const GuestRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> headers;
  final Uint8List body;

  String? get host => headers['host'];
}

/// Parses HTTP/1.1 requests out of a byte stream.
///
/// Returns null until a complete request is buffered, so a caller can feed it
/// whatever arrives without tracking message boundaries itself.
class GuestRequestParser {
  final List<int> _buffer = [];

  void add(Uint8List data) => _buffer.addAll(data);

  /// Takes the next complete request, or null when one has not arrived.
  GuestRequest? take() {
    final text = latin1.decode(_buffer, allowInvalid: true);
    final headerEnd = text.indexOf(_Http.headerEnd);
    if (headerEnd < 0) {
      return null;
    }

    final head = text.substring(0, headerEnd);
    final lines = head.split(_Http.lineEnd);
    if (lines.isEmpty) {
      return null;
    }
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) {
      return null;
    }

    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
    }

    final bodyStart = headerEnd + _Http.headerEnd.length;
    final declared = int.tryParse(headers['content-length'] ?? '0') ?? 0;
    if (_buffer.length < bodyStart + declared) {
      return null; // the body is still arriving
    }

    final body = Uint8List.fromList(
      _buffer.sublist(bodyStart, bodyStart + declared),
    );
    _buffer.removeRange(0, bodyStart + declared);

    return GuestRequest(
      method: requestLine[0],
      path: requestLine[1],
      headers: headers,
      body: body,
    );
  }
}

/// Why a request was refused, in terms the agent can act on.
class ProxyRefusal implements Exception {
  const ProxyRefusal(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Turns guest requests into host requests, applying the upstream policy.
class HttpProxy {
  HttpProxy({
    required List<Upstream> upstreams,
    required this.credentials,
    required this.transport,
  }) : _byHost = {for (final u in upstreams) u.host.toLowerCase(): u};

  final Map<String, Upstream> _byHost;
  final CredentialStore credentials;
  final ProxyTransport transport;

  /// Whether any upstream is configured for this host.
  bool allows(String? host) =>
      host != null && _byHost.containsKey(_hostOnly(host));

  static String _hostOnly(String host) {
    final colon = host.indexOf(':');
    return (colon < 0 ? host : host.substring(0, colon)).toLowerCase();
  }

  /// Builds the outbound request, or throws [ProxyRefusal] when policy or a
  /// missing credential forbids it.
  ProxyRequest resolve(GuestRequest request) {
    final upstream = _byHost[_hostOnly(request.host ?? '')];
    if (upstream == null) {
      throw ProxyRefusal(
        _Http.badGateway,
        'No upstream is configured for "${request.host}". This machine can '
        'only reach the destinations its host allows.',
      );
    }

    final headers = <String, String>{};
    for (final entry in request.headers.entries) {
      // Hop-by-hop and body-framing headers are the host's business.
      if (entry.key == 'host' ||
          entry.key == 'content-length' ||
          entry.key == 'connection') {
        continue;
      }
      headers[entry.key] = entry.value;
    }
    for (final entry in upstream.injectHeaders.entries) {
      final name = entry.key.toLowerCase();
      headers[name] = _checkSendable(name, _substitute(entry.value));
    }

    return ProxyRequest(
      method: request.method,
      url: _join(upstream.target, request.path),
      headers: headers,
      body: request.body,
    );
  }

  /// Appends the guest's path to the upstream's own.
  ///
  /// Uri.resolve would treat an absolute path as a replacement and discard
  /// any prefix the upstream carries, sending /v1/… to the site root rather
  /// than to its API.
  static Uri _join(Uri target, String path) {
    final query = path.indexOf('?');
    final justPath = query < 0 ? path : path.substring(0, query);
    final base = target.path.endsWith('/')
        ? target.path.substring(0, target.path.length - 1)
        : target.path;
    final tail = justPath.startsWith('/') ? justPath : '/$justPath';
    return target.replace(
      path: '$base$tail',
      query: query < 0 ? null : path.substring(query + 1),
    );
  }

  /// Rejects a header value a browser cannot send, while it is still clear
  /// whose value it is.
  ///
  /// An HTTP header carries bytes, so anything above U+00FF has no
  /// representation in one. A key pasted from a rendered page can pick up a
  /// non-breaking space or a zero-width character without looking any
  /// different, and `fetch` then refuses the whole request with a TypeError
  /// naming nothing — which sends the reader looking at the transport
  /// instead of at the value they pasted.
  static String _checkSendable(String name, String value) {
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code > 0xFF || code < 0x20 || code == 0x7F) {
        throw ProxyRefusal(
          _Http.credentialMissing,
          'The value configured for the "$name" header contains a character '
          'that cannot be sent in an HTTP header (code point U+'
          '${code.toRadixString(16).toUpperCase().padLeft(4, '0')} at '
          'position $i). A credential copied from a web page can pick up a '
          'non-breaking space or a hidden character; retyping it usually '
          'fixes this.',
        );
      }
    }
    return value;
  }

  /// Replaces `${NAME}` with the credential of that name.
  String _substitute(String value) => value.replaceAllMapped(_placeholder, (
    match,
  ) {
    final name = match.group(1)!;
    final secret = credentials[name];
    if (secret == null) {
      throw ProxyRefusal(
        _Http.credentialMissing,
        'No credential is configured for $name. Enter a key on the page to '
        'continue; this machine never holds one itself.',
      );
    }
    return secret;
  });

  /// Runs one guest request end to end, always producing a response the
  /// guest can read — a refusal is reported to the agent, not dropped.
  Future<Uint8List> handle(GuestRequest request) async {
    try {
      final outbound = resolve(request);
      final response = await transport(outbound);
      return renderResponse(response);
    } on ProxyRefusal catch (refusal) {
      return renderRefusal(refusal);
    } on Object catch (error) {
      return renderRefusal(
        ProxyRefusal(_Http.badGateway, 'The request could not be sent: $error'),
      );
    }
  }
}

/// Serialises a response the way the guest's HTTP client expects it.
Uint8List renderResponse(ProxyResponse response) {
  final head = StringBuffer()
    ..write('${_Http.version} ${response.statusCode} ')
    ..write(_reason(response.statusCode))
    ..write(_Http.lineEnd);
  for (final entry in response.headers.entries) {
    final name = entry.key.toLowerCase();
    // The length and framing are rewritten to match what is actually sent.
    if (name == 'content-length' ||
        name == 'transfer-encoding' ||
        name == 'connection') {
      continue;
    }
    head.write('${entry.key}: ${entry.value}${_Http.lineEnd}');
  }
  head
    ..write('Content-Length: ${response.body.length}${_Http.lineEnd}')
    ..write('Connection: close${_Http.lineEnd}')
    ..write(_Http.lineEnd);

  return Uint8List.fromList([
    ...latin1.encode(head.toString()),
    ...response.body,
  ]);
}

/// Renders a refusal as a JSON error body, so an agent expecting an API
/// response can read the reason instead of seeing a dead socket.
Uint8List renderRefusal(ProxyRefusal refusal) {
  final body = utf8.encode(
    jsonEncode({
      'error': {'message': refusal.message, 'type': 'dartemu_proxy'},
    }),
  );
  return renderResponse(
    ProxyResponse(
      statusCode: refusal.statusCode,
      headers: const {'content-type': 'application/json'},
      body: Uint8List.fromList(body),
    ),
  );
}

String _reason(int status) => switch (status) {
  200 => 'OK',
  400 => 'Bad Request',
  401 => 'Unauthorized',
  403 => 'Forbidden',
  404 => 'Not Found',
  429 => 'Too Many Requests',
  500 => 'Internal Server Error',
  502 => 'Bad Gateway',
  _ => 'Status',
};
