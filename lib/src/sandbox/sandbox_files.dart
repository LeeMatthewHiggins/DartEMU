import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/sandbox/agent_sandbox.dart';
import 'package:dart_emu/src/sandbox/exec_result.dart';

/// File exchange between host and guest over the console.
///
/// Uses base64 framing so arbitrary bytes cross a text-only channel:
/// writes stream base64 into `base64 -d` via a quoted heredoc; reads
/// run `base64` in the guest and decode its stdout. This needs nothing
/// beyond the busybox `base64` applet already in the rootfs, so it
/// works on every platform including the browser. It is convenient
/// rather than fast; for bulk data, attach a second block device.
extension SandboxFiles on AgentSandbox {
  /// Writes [data] to [guestPath] inside the guest.
  ///
  /// Returns the result of the underlying decode command; check
  /// [ExecResult.succeeded]. Fails if the parent directory is missing.
  Future<ExecResult> writeFile(
    String guestPath,
    List<int> data, {
    Duration? timeout,
  }) {
    final encoded = base64.encode(data);
    final wrapped = _wrap(encoded, _lineWidth);
    // Quoted heredoc terminator => the shell performs no expansion on
    // the base64 body, so it is delivered to `base64 -d` verbatim.
    final command =
        "base64 -d > ${_quote(guestPath)} <<'$_heredocTag'\n"
        '$wrapped\n'
        '$_heredocTag';
    return exec(command, timeout: timeout);
  }

  /// Writes [text] (UTF-8) to [guestPath] inside the guest.
  Future<ExecResult> writeText(
    String guestPath,
    String text, {
    Duration? timeout,
  }) => writeFile(guestPath, utf8.encode(text), timeout: timeout);

  /// Reads [guestPath] from the guest and returns its bytes.
  ///
  /// Throws [SandboxFileException] if the file cannot be read.
  Future<Uint8List> readFile(String guestPath, {Duration? timeout}) async {
    final result = await exec('base64 ${_quote(guestPath)}', timeout: timeout);
    if (!result.succeeded) {
      throw SandboxFileException(
        'read failed for "$guestPath" (exit ${result.exitCode})',
        result.stdout,
      );
    }
    final cleaned = result.stdout.replaceAll(RegExp(r'\s'), '');
    try {
      return base64.decode(cleaned);
    } on FormatException catch (e) {
      throw SandboxFileException(
        'decode failed for "$guestPath": ${e.message}',
        result.stdout,
      );
    }
  }

  /// Reads [guestPath] from the guest and decodes it as UTF-8 text.
  Future<String> readText(String guestPath, {Duration? timeout}) async =>
      utf8.decode(await readFile(guestPath, timeout: timeout));

  String _wrap(String data, int width) {
    if (data.length <= width) return data;
    final buffer = StringBuffer();
    for (var i = 0; i < data.length; i += width) {
      if (i > 0) buffer.write('\n');
      final end = i + width < data.length ? i + width : data.length;
      buffer.write(data.substring(i, end));
    }
    return buffer.toString();
  }

  String _quote(String path) => "'${path.replaceAll("'", r"'\''")}'";

  /// Base64 line width, kept well under the tty canonical line limit.
  static const _lineWidth = 120;
  static const _heredocTag = '__SBX_B64__';
}

/// Thrown when a host/guest file transfer fails.
class SandboxFileException implements Exception {
  SandboxFileException(this.message, this.consoleOutput);

  final String message;

  /// Guest output captured during the failed transfer.
  final String consoleOutput;

  @override
  String toString() => 'SandboxFileException: $message';
}
