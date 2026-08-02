import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_emu_example/src/config/bundle_prefill.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bundle {
  static const configYaml = '''
version: 1
machine: riscv32
memory_size: 32
kernel: kernel.bin
''';

  /// A structurally valid bundle: one YAML config and the kernel it names.
  static Uint8List build() {
    final kernel = Uint8List.fromList(List.filled(64, 0x42));
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('config.yaml', utf8.encode(configYaml)))
      ..addFile(ArchiveFile.bytes('kernel.bin', kernel));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

Widget _picker({String? url, BundleFetcher? fetcher}) => MaterialApp(
  home: ConfigPickerScreen(
    prefillBundleUrl: url,
    bundleFetcher: fetcher ?? fetchBundleBytes,
    onConfigLoaded: (_) {},
    onDemoSelected: (_) {},
    onDemoWithShare: (_, __, ___) {},
    onAgentOsSelected: (_) {},
  ),
);

void main() {
  testWidgets('a bundle URL preloads the config and offers Boot', (
    tester,
  ) async {
    final requested = <Uri>[];
    await tester.pumpWidget(
      _picker(
        url: 'vms/demo.zip',
        fetcher: (url) async {
          requested.add(url);
          return _Bundle.build();
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      requested.single.path,
      endsWith('vms/demo.zip'),
      reason: 'relative URLs resolve against the page address',
    );
    expect(find.text('Boot'), findsOneWidget);
  });

  testWidgets('a failed download surfaces the error, not a blank screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _picker(
        url: 'vms/missing.zip',
        fetcher: (url) async =>
            throw BundleFetchException('Could not download $url: HTTP 404'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(find.text('Boot'), findsNothing);
  });

  testWidgets('a zip without a config is reported, not thrown', (tester) async {
    final empty = Uint8List.fromList(ZipEncoder().encode(Archive()));
    await tester.pumpWidget(
      _picker(url: 'vms/empty.zip', fetcher: (_) async => empty),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No .yaml or .yml config'), findsOneWidget);
    expect(find.text('Boot'), findsNothing);
  });

  testWidgets('no bundle parameter leaves the picker untouched', (
    tester,
  ) async {
    var fetched = false;
    await tester.pumpWidget(
      _picker(
        fetcher: (_) async {
          fetched = true;
          return _Bundle.build();
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(fetched, isFalse);
    expect(find.text('Boot'), findsNothing);
  });
}
