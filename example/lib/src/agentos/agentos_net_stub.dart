import 'package:dart_emu/dart_emu.dart';

/// Stand-in for platforms with no proxying backend.
///
/// The demo is offered only where the browser proxy exists, so this is here
/// to keep the desktop build compiling rather than to be called.
NetBackend createAgentOsBackend({
  required List<Upstream> upstreams,
  required CredentialStore credentials,
}) {
  throw UnsupportedError(
    'The AgentOS demo needs the browser proxy, which only the web build has.',
  );
}
