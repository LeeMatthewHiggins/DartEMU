import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Fetches the bytes of a VM bundle for the `?bundle=` URL parameter.
typedef BundleFetcher = Future<Uint8List> Function(Uri url);

/// Thrown when a prefill bundle cannot be downloaded.
class BundleFetchException implements Exception {
  /// Creates the exception with a user-facing [message].
  const BundleFetchException(this.message);

  /// Why the bundle could not be fetched.
  final String message;

  @override
  String toString() => message;
}

class _Http {
  static const ok = 200;
}

/// Downloads a bundle over HTTP.
///
/// A cross-origin URL only works when its host sends CORS headers; bundles
/// hosted alongside the app itself always work, which is why relative URLs
/// are the recommended form.
Future<Uint8List> fetchBundleBytes(Uri url) async {
  final http.Response response;
  try {
    response = await http.get(url);
  } on Object catch (e) {
    throw BundleFetchException(
      'Could not download $url: $e\n'
      'If the bundle lives on another host, that host must allow '
      'cross-origin requests.',
    );
  }
  if (response.statusCode != _Http.ok) {
    throw BundleFetchException(
      'Could not download $url: HTTP ${response.statusCode}',
    );
  }
  return response.bodyBytes;
}
