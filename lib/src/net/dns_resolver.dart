import 'dart:typed_data';

import 'package:dart_emu/src/net/net_const.dart';

/// Callback that resolves a hostname to a list of IPv4 addresses.
typedef DnsLookupCallback = List<Uint8List>? Function(String hostname);

/// Parses DNS queries and builds A-record responses.
class DnsResolver {
  /// Handles a DNS query payload and returns a response, or `null`.
  ///
  /// Returns `null` only when the query is malformed or an A-record
  /// lookup is still pending. For non-A queries (e.g. AAAA), returns
  /// an empty response so the guest resolver can proceed.
  Uint8List? handleQuery(Uint8List data, DnsLookupCallback lookup) {
    if (data.length < DnsConst.headerSize) return null;
    final view = ByteData.sublistView(data);
    final id = view.getUint16(0);
    final qdCount = view.getUint16(_qdCountOffset);
    if (qdCount == 0) return null;

    final (hostname, nameEnd) = _parseName(data, DnsConst.headerSize);
    if (hostname == null || nameEnd == null) return null;
    if (data.length < nameEnd + 4) return null;

    final questionEnd = nameEnd + 4;
    final qType = ByteData.sublistView(data).getUint16(nameEnd);
    final qClass = ByteData.sublistView(data).getUint16(nameEnd + 2);

    if (qType != DnsConst.typeA || qClass != DnsConst.classIn) {
      return _buildEmptyResponse(id, data, questionEnd);
    }

    final addresses = lookup(hostname);
    if (addresses == null || addresses.isEmpty) return null;

    return _buildResponse(id, data, questionEnd, addresses);
  }

  static Uint8List _buildEmptyResponse(
    int id,
    Uint8List query,
    int questionEnd,
  ) {
    final questionSection = Uint8List.sublistView(
      query,
      DnsConst.headerSize,
      questionEnd,
    );
    final response = Uint8List(DnsConst.headerSize + questionSection.length)
      ..setRange(
        DnsConst.headerSize,
        DnsConst.headerSize + questionSection.length,
        questionSection,
      );
    ByteData.sublistView(response)
      ..setUint16(0, id)
      ..setUint16(_flagsOffset, DnsConst.flagsResponse)
      ..setUint16(_qdCountOffset, 1)
      ..setUint16(_anCountOffset, 0);
    return response;
  }

  static Uint8List _buildResponse(
    int id,
    Uint8List query,
    int questionEnd,
    List<Uint8List> addresses,
  ) {
    final questionSection = Uint8List.sublistView(
      query,
      DnsConst.headerSize,
      questionEnd,
    );

    // Each answer: name pointer (2) + type (2) + class (2)
    //   + TTL (4) + rdlength (2) + rdata (4) = 16 bytes
    final answerSize = addresses.length * _answerRecordSize;
    final responseLength =
        DnsConst.headerSize + questionSection.length + answerSize;

    final response = Uint8List(responseLength)
      ..setRange(
        DnsConst.headerSize,
        DnsConst.headerSize + questionSection.length,
        questionSection,
      );
    ByteData.sublistView(response)
      ..setUint16(0, id)
      ..setUint16(_flagsOffset, DnsConst.flagsResponse)
      ..setUint16(_qdCountOffset, 1)
      ..setUint16(_anCountOffset, addresses.length);

    var offset = DnsConst.headerSize + questionSection.length;
    for (final addr in addresses) {
      ByteData.sublistView(response, offset)
        ..setUint16(0, _namePointerBase | DnsConst.headerSize)
        ..setUint16(2, DnsConst.typeA)
        ..setUint16(4, DnsConst.classIn)
        ..setUint32(6, DnsConst.defaultTtl)
        ..setUint16(10, 4);
      response.setRange(offset + 12, offset + 16, addr);
      offset += _answerRecordSize;
    }

    return response;
  }

  static (String?, int?) _parseName(Uint8List data, int offset) {
    final parts = <String>[];
    var pos = offset;
    while (pos < data.length) {
      final length = data[pos];
      if (length == 0) {
        pos++;
        break;
      }
      if ((length & 0xC0) == 0xC0) {
        return (null, null); // Compressed names not supported in queries.
      }
      pos++;
      if (pos + length > data.length) return (null, null);
      parts.add(String.fromCharCodes(
        Uint8List.sublistView(data, pos, pos + length),
      ));
      pos += length;
    }
    if (parts.isEmpty) return (null, null);
    return (parts.join('.'), pos);
  }

  static const _flagsOffset = 2;
  static const _qdCountOffset = 4;
  static const _anCountOffset = 6;
  static const _namePointerBase = 0xC000;
  static const _answerRecordSize = 16;
}
