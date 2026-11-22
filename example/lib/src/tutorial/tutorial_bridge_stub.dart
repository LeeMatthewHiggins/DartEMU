import 'package:dart_emu_example/src/tutorial/tutorial_session.dart';

/// Native applications do not expose the browser tutorial bridge.
TutorialSession? createTutorialBridge({
  required void Function(String) sendInput,
}) => null;
