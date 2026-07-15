@Tags(['version-verify'])
library;

import 'dart:io';

import 'package:dart_emu/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionLine = pubspec
        .split('\n')
        .firstWhere((line) => line.startsWith('version:'));
    final pubspecVersion = versionLine.split(':').last.trim();
    expect(packageVersion, pubspecVersion);
  });
}
