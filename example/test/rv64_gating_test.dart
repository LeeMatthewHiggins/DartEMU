import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:dart_emu_example/src/config/rv64_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A structurally valid RV64 bundle: one YAML config and the kernel it names.
Uint8List _rv64Bundle() {
  const configYaml = '''
version: 1
machine: riscv64
memory_size: 64
kernel: kernel.bin
''';
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('config.yaml', utf8.encode(configYaml)))
    ..addFile(ArchiveFile.bytes('kernel.bin', Uint8List(64)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Widget _picker({required bool rv64Supported}) => MaterialApp(
  home: ConfigPickerScreen(
    prefillBundleUrl: 'vms/rv64.zip',
    bundleFetcher: (_) async => _rv64Bundle(),
    rv64Supported: rv64Supported,
    onConfigLoaded: (_) {},
    onDemoSelected: (_) {},
    onDemoWithShare: (_, __, ___) {},
    onAgentOsSelected: (_) {},
  ),
);

void main() {
  testWidgets('an RV64 bundle on a build without RV64 explains, not crashes', (
    tester,
  ) async {
    await tester.pumpWidget(_picker(rv64Supported: false));
    await tester.pumpAndSettle();

    expect(find.textContaining('WebAssembly'), findsOneWidget);
    expect(
      find.text('Boot'),
      findsNothing,
      reason: 'offering Boot would lead straight into the Int64List crash',
    );
  });

  testWidgets('the same bundle boots normally where RV64 is available', (
    tester,
  ) async {
    await tester.pumpWidget(_picker(rv64Supported: true));
    await tester.pumpAndSettle();

    expect(find.text('Boot'), findsOneWidget);
    expect(find.textContaining('WebAssembly'), findsNothing);
  });

  test('this build reports RV64 support truthfully for its platform', () {
    // VM test runs are native, where RV64 always works; the constant must
    // never gate anything off outside the JavaScript web build.
    expect(isRv64Supported, isTrue);
  });
}
