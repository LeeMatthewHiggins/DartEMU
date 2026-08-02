import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/agentos/agentos_net_adapter.dart';
import 'package:dart_emu_example/src/config/rv64_support.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class _AgentOsAssets {
  static const bios = 'assets/bbl64.bin';
  static const kernel = 'assets/kernel-riscv64.bin';
  static const rootfs = 'assets/agentos-riscv64.bin';
}

/// The AgentOS demo: a machine whose console is an agent rather than a shell.
///
/// The image contains no credential and has no field able to hold one. It
/// addresses the model by a name that resolves back to this page, and sends a
/// placeholder where a key would go. The real key — when the visitor has
/// supplied one — is substituted here, on the way out, and never crosses into
/// the guest.
class AgentOsDemo {
  /// Creates nothing; the demo is a set of definitions and a builder.
  const AgentOsDemo._();

  /// The name the guest's placeholder refers to.
  static const credentialName = 'OPENROUTER_KEY';

  /// What the guest calls the model, and where that actually goes.
  static const upstreamHost = 'llm.local';
  static final upstreamTarget = Uri.parse('https://openrouter.ai/api');

  /// Kernel messages are left on: an emulated boot takes a while, and a
  /// visitor watching a blank screen has no way to tell it apart from a
  /// machine that has hung.
  static const _cmdLine =
      'console=hvc0 root=/dev/vda rw init=/init loglevel=7 earlyprintk';

  /// Whether this build can run the demo.
  ///
  /// The guest is RV64, and the proxy that gives it a network is built on
  /// `fetch`, so it needs both a browser and the WasmGC backend.
  static const isSupported = kIsWeb && isRv64Supported;

  /// The only destination the guest can reach.
  static List<Upstream> upstreams() => [
    Upstream(
      host: upstreamHost,
      target: upstreamTarget,
      injectHeaders: const {'authorization': 'Bearer \${$credentialName}'},
    ),
  ];

  /// Builds the machine, with [credentials] held here rather than in it.
  static Future<MachineConfig> buildConfig(CredentialStore credentials) async {
    final assets = await Future.wait([
      rootBundle.load(_AgentOsAssets.bios),
      rootBundle.load(_AgentOsAssets.kernel),
      rootBundle.load(_AgentOsAssets.rootfs),
    ]);

    return MachineConfig(
      biosData: assets[0].buffer.asUint8List(),
      kernelData: assets[1].buffer.asUint8List(),
      cmdLine: _cmdLine,
      blockDevices: [
        MemoryBlockDevice.fromData(assets[2].buffer.asUint8List()),
      ],
      ethDevices: [
        UserNetDevice(
          backend: createAgentOsBackend(
            upstreams: upstreams(),
            credentials: credentials,
          ),
        ),
      ],
    );
  }
}
