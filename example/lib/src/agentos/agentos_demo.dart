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
  ///
  /// This and [upstreamHost] are compiled into the guest as well, in
  /// `agentos/src/llm.c`, and nothing checks that the two agree — one side is
  /// C in an emulated machine and the other is Dart on a page. Change one and
  /// the guest addresses a host this proxy has never heard of.
  static const credentialName = 'OPENROUTER_KEY';

  /// What the guest calls the model, and where that actually goes.
  static const upstreamHost = 'llm.local';
  static final upstreamTarget = Uri.parse('https://openrouter.ai/api');

  /// Kernel messages are left on: an emulated boot takes a while, and a
  /// visitor watching a blank screen has no way to tell it apart from a
  /// machine that has hung.
  static const _cmdLine =
      'console=hvc0 root=/dev/vda rw init=/init loglevel=7 earlyprintk';

  /// Models a visitor can pick between.
  ///
  /// The choice exists because an OpenRouter account's data policy decides
  /// which providers it may reach, and a model whose every endpoint is ruled
  /// out fails with a message about the account rather than about anything
  /// here. Offering alternatives is the difference between a demo that is
  /// broken for someone and one they can still use.
  static const models = <String>[
    'moonshotai/kimi-k3',
    'openai/gpt-4o-mini',
    'anthropic/claude-haiku-4.5',
  ];

  /// The model used when a visitor expresses no preference.
  static const defaultModel = 'moonshotai/kimi-k3';

  /// Rejects anything that could add a second word to the command line.
  ///
  /// The model reaches the guest as a kernel parameter, so a value carrying
  /// whitespace would not be one parameter any more. Slashes, dots and
  /// hyphens are what real model names are made of.
  static final _modelShape = RegExp(r'^[A-Za-z0-9._/-]+$');

  static bool isValidModel(String model) =>
      model.isNotEmpty && model.length <= 100 && _modelShape.hasMatch(model);

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

  /// Builds the command line, carrying the model the visitor chose.
  ///
  /// This is the only setting the page hands to the guest. Where requests go
  /// and what they carry stays on this side, so a guest that rewrote its own
  /// command line would still reach nothing new.
  static String cmdLineFor(String model) {
    final chosen = isValidModel(model) ? model : defaultModel;
    return '$_cmdLine agentos.model=$chosen';
  }

  /// Builds the machine, with [credentials] held here rather than in it.
  static Future<MachineConfig> buildConfig(
    CredentialStore credentials, {
    String model = defaultModel,
  }) async {
    final assets = await Future.wait([
      rootBundle.load(_AgentOsAssets.bios),
      rootBundle.load(_AgentOsAssets.kernel),
      rootBundle.load(_AgentOsAssets.rootfs),
    ]);

    return MachineConfig(
      biosData: assets[0].buffer.asUint8List(),
      kernelData: assets[1].buffer.asUint8List(),
      cmdLine: cmdLineFor(model),
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
