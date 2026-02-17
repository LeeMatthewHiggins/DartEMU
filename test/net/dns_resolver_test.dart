import 'dart:typed_data';

import 'package:dart_emu/src/net/dns_resolver.dart';
import 'package:dart_emu/src/net/net_const.dart';
import 'package:test/test.dart';

void main() {
  group('DnsResolver', () {
    final resolver = DnsResolver();

    Uint8List buildQuery(String hostname) {
      final labels = hostname.split('.');
      final nameBytes = <int>[];
      for (final label in labels) {
        nameBytes
          ..add(label.length)
          ..addAll(label.codeUnits);
      }
      nameBytes.add(0);
      final data = Uint8List(12 + nameBytes.length + 4);
      final header = ByteData.sublistView(data)
        ..setUint16(0, 0x1234)
        ..setUint16(2, 0x0100)
        ..setUint16(4, 1);
      data.setRange(12, 12 + nameBytes.length, nameBytes);
      final qOffset = 12 + nameBytes.length;
      header
        ..setUint16(qOffset, DnsConst.typeA)
        ..setUint16(qOffset + 2, DnsConst.classIn);
      return data;
    }

    test('resolves hostname to A-record response', () {
      final query = buildQuery('example.com');
      final ip = Uint8List.fromList([93, 184, 216, 34]);
      final response = resolver.handleQuery(
        query,
        (h) => h == 'example.com' ? [ip] : null,
      );

      expect(response, isNotNull);
      final view = ByteData.sublistView(response!);

      expect(view.getUint16(0), 0x1234);
      expect(view.getUint16(2), DnsConst.flagsResponse);
      expect(view.getUint16(4), 1);
      expect(view.getUint16(6), 1);

      final answerIp = Uint8List.sublistView(
        response,
        response.length - 4,
      );
      expect(answerIp, ip);
    });

    test('returns null when lookup returns null', () {
      final query = buildQuery('unknown.test');
      final response = resolver.handleQuery(
        query,
        (_) => null,
      );
      expect(response, isNull);
    });

    test('returns null when lookup returns empty', () {
      final query = buildQuery('empty.test');
      final response = resolver.handleQuery(
        query,
        (_) => [],
      );
      expect(response, isNull);
    });

    test('returns null for too-short data', () {
      expect(
        resolver.handleQuery(Uint8List(11), (_) => null),
        isNull,
      );
    });

    test('returns null for zero question count', () {
      final data = Uint8List(20);
      ByteData.sublistView(data)
        ..setUint16(0, 0x1234)
        ..setUint16(2, 0x0100)
        ..setUint16(4, 0);
      expect(
        resolver.handleQuery(data, (_) => null),
        isNull,
      );
    });

    test('returns empty response for AAAA query', () {
      final query = buildQuery('example.com');
      // Patch qType from A (1) to AAAA (28).
      const nameEnd = 12 + 'example'.length + 1 + 'com'.length + 1 + 1;
      ByteData.sublistView(query).setUint16(nameEnd, 28);

      final response = resolver.handleQuery(query, (_) => null);

      expect(response, isNotNull);
      final view = ByteData.sublistView(response!);
      expect(view.getUint16(0), 0x1234);
      expect(view.getUint16(2), DnsConst.flagsResponse);
      expect(view.getUint16(4), 1);
      expect(view.getUint16(6), 0);
    });

    test('handles multiple A-records', () {
      final query = buildQuery('multi.test');
      final ips = [
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([5, 6, 7, 8]),
      ];
      final response = resolver.handleQuery(
        query,
        (_) => ips,
      );

      expect(response, isNotNull);
      final view = ByteData.sublistView(response!);
      expect(view.getUint16(6), 2);

      final ip1 = Uint8List.sublistView(
        response,
        response.length - 20,
        response.length - 16,
      );
      expect(ip1, ips[0]);

      final ip2 = Uint8List.sublistView(
        response,
        response.length - 4,
      );
      expect(ip2, ips[1]);
    });
  });
}
