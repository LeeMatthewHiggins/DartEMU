import 'package:dart_emu/dart_emu_web.dart';

/// The File System Access directory picker is available on the web.
bool get isFolderPickerSupported => true;

/// Prompts for a directory and loads it into an in-memory 9P share.
Future<PickedShare?> pickFolderShare() => pickDirectoryShare();
