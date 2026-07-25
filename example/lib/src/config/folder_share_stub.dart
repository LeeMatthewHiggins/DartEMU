import 'package:dart_emu/dart_emu.dart';

/// Whether the browser directory picker is available on this platform.
bool get isFolderPickerSupported => false;

/// Native fallback: there is no browser directory picker.
Future<PickedShare?> pickFolderShare() async => null;
