import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_emu/src/device/character_device.dart';

/// Console device for the agent sandbox.
///
/// Accumulates guest output in a growable byte buffer and supports
/// incremental marker scanning: each [markerFound] call only examines
/// bytes appended since the previous call, so polling stays O(new
/// bytes) rather than re-scanning the whole transcript.
class SandboxConsole implements CharacterDevice {
  Uint8List _buffer = Uint8List(_initialCapacity);
  int _length = 0;
  final List<int> _input = [];

  Uint8List _marker = Uint8List(0);
  int _scanPos = 0;
  int _markerStart = 0;
  int _markerEnd = 0;
  int _phaseStart = 0;

  static const _initialCapacity = 64 * 1024;

  /// Begins waiting for [marker], scanning from the current end.
  void beginWait(String marker) {
    _marker = Uint8List.fromList(ascii.encode(marker));
    _scanPos = _length;
    _phaseStart = _length;
  }

  /// Whether the current marker has appeared since [beginWait].
  ///
  /// Advances the internal scan position so unmatched bytes are never
  /// re-examined on later calls.
  bool markerFound() {
    final marker = _marker;
    if (marker.isEmpty) return false;
    final limit = _length - marker.length;
    var pos = _scanPos;

    while (pos <= limit) {
      if (_buffer[pos] == marker[0] && _matchesAt(pos, marker)) {
        _markerStart = pos;
        _markerEnd = pos + marker.length;
        _scanPos = _markerEnd;
        return true;
      }
      pos++;
    }

    _scanPos = pos < _phaseStart ? _phaseStart : pos;
    return false;
  }

  bool _matchesAt(int pos, Uint8List marker) {
    for (var i = 1; i < marker.length; i++) {
      if (_buffer[pos + i] != marker[i]) return false;
    }
    return true;
  }

  /// Raw bytes produced between [beginWait] and the matched marker.
  String phaseOutput() => utf8.decode(
    Uint8List.sublistView(_buffer, _phaseStart, _markerStart),
    allowMalformed: true,
  );

  /// The text immediately following the matched marker up to the next
  /// newline (used to read a trailing exit-status field).
  String markerTail() {
    var end = _markerEnd;
    while (end < _length && _buffer[end] != _lf) {
      end++;
    }
    return utf8.decode(
      Uint8List.sublistView(_buffer, _markerEnd, end),
      allowMalformed: true,
    );
  }

  /// The last [maxLength] bytes of output, for timeout diagnostics.
  String tail({int maxLength = _tailLength}) {
    final start = _length > maxLength ? _length - maxLength : 0;
    return utf8.decode(
      Uint8List.sublistView(_buffer, start, _length),
      allowMalformed: true,
    );
  }

  /// Queues [bytes] as guest console input.
  void feedInput(List<int> bytes) => _input.addAll(bytes);

  /// Whether all queued input has been consumed by the guest.
  bool get inputDrained => _input.isEmpty;

  @override
  void writeData(Uint8List data) {
    if (_length + data.length > _buffer.length) {
      _grow(_length + data.length);
    }
    _buffer.setRange(_length, _length + data.length, data);
    _length += data.length;
  }

  void _grow(int needed) {
    var capacity = _buffer.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
  }

  @override
  Uint8List readData(int maxLength) {
    if (_input.isEmpty) return Uint8List(0);
    final count = maxLength < _input.length ? maxLength : _input.length;
    final result = Uint8List.fromList(_input.sublist(0, count));
    _input.removeRange(0, count);
    return result;
  }

  static const _lf = 0x0A;
  static const _tailLength = 800;
}
