import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu/dart_emu_web.dart' show WebNetBackend;

/// Gives the guest its only route out: a proxy on this page that reaches the
/// configured upstreams and attaches the credentials the guest never holds.
NetBackend createAgentOsBackend({
  required List<Upstream> upstreams,
  required CredentialStore credentials,
}) => WebNetBackend(upstreams: upstreams, credentials: credentials);
