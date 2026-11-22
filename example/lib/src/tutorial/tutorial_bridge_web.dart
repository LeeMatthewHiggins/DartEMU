import 'dart:js_interop';

import 'package:dart_emu_example/src/tutorial/tutorial_session.dart';

/// Enables the fixed examples only for an explicitly opted-in iframe.
TutorialSession? createTutorialBridge({
  required void Function(String) sendInput,
}) {
  final parent = _window.parent;
  final origin = _window.location.origin;
  if (Uri.base.queryParameters['tutorial'] != '1' ||
      parent.strictEquals(_window).toDart ||
      origin == 'null') {
    return null;
  }

  late final JSFunction listener;
  final session = TutorialSession(
    sendInput: sendInput,
    postMessage: (message) => parent.postMessage(message.jsify(), origin),
    onDispose: () => _window.removeEventListener('message', listener),
  );
  listener = ((_MessageEvent event) {
    if (event.origin != origin || !event.source.strictEquals(parent).toDart) {
      return;
    }
    try {
      session.receiveMessage(event.data.dartify());
    } on Object {
      // Unsupported or malformed message data is unrelated to this tutorial.
    }
  }).toJS;
  _window.addEventListener('message', listener);
  return session;
}

@JS('window')
external _BrowserWindow get _window;

extension type _BrowserWindow._(JSObject _) implements JSObject {
  external _BrowserWindow get parent;
  external _Location get location;
  external void postMessage(JSAny? message, String targetOrigin);
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _Location._(JSObject _) implements JSObject {
  external String get origin;
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external String get origin;
  external JSAny? get source;
  external JSAny? get data;
}
