/// Selects the proxying network backend available on this platform.
library;

export 'package:dart_emu_example/src/agentos/agentos_net_stub.dart'
    if (dart.library.js_interop) 'package:dart_emu_example/src/agentos/agentos_net_web.dart';
