import 'package:dart_emu/dart_emu_web.dart';

/// Whether this browser actually exposes the directory picker (not merely
/// that we compiled for the web).
bool get isFolderPickerSupported => isDirectoryPickerSupported;

/// Prompts for a directory and loads it into a 9P share.
Future<PickedShare?> pickFolderShare() => pickDirectoryShare();
