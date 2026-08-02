import 'dart:js_interop';

import 'package:dart_emu/src/net/http_proxy.dart';

/// Issues the guest's request with the browser's `fetch`.
///
/// This is the only part of the proxy that is web-specific: the parsing,
/// policy and credential handling are plain Dart so they can be tested on
/// the VM.
Future<ProxyResponse> fetchTransport(ProxyRequest request) async {
  final headers = <String, String>{...request.headers};

  final init = _RequestInit(
    method: request.method,
    headers: headers.entries
        .map((e) => <JSString>[e.key.toJS, e.value.toJS].toJS)
        .toList()
        .toJS,
    body: request.body.isEmpty ? null : request.body.toJS,
  );

  final response = await _fetch(request.url.toString().toJS, init).toDart;
  final buffer = await response.arrayBuffer().toDart;
  final body = (buffer as JSArrayBuffer).toDart.asUint8List();

  final responseHeaders = <String, String>{};
  final contentType = response.headers.get('content-type'.toJS);
  if (contentType != null) {
    responseHeaders['content-type'] = contentType.toDart;
  }

  return ProxyResponse(
    statusCode: response.status,
    headers: responseHeaders,
    body: body,
  );
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, _RequestInit init);

extension type _RequestInit._(JSObject _) implements JSObject {
  external factory _RequestInit({
    String method,
    JSArray<JSArray<JSString>> headers,
    JSUint8Array? body,
  });
}

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external _Headers get headers;
  external JSPromise<JSObject> arrayBuffer();
}

extension type _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}
