/// Optional messaging support for the embedded browser tutorial.
library;

export 'tutorial_bridge_stub.dart'
    if (dart.library.js_interop) 'tutorial_bridge_web.dart'
    show createTutorialBridge;
export 'tutorial_session.dart' show TutorialSession;
