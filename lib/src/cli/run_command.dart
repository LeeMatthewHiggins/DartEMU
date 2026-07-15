import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_emu/src/emulator/emulator.dart';
import 'package:dart_emu/src/machine/config_loader.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:mason_logger/mason_logger.dart';

class RunCommand extends Command<int> {
  RunCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Path to a YAML configuration file.',
      )
      ..addOption(
        'memory',
        abbr: 'm',
        help: 'RAM size in megabytes.',
        defaultsTo: '${MachineConfig.defaultMemorySizeMb}',
      )
      ..addOption('bios', help: 'Path to the BIOS/bootloader binary.')
      ..addOption('kernel', help: 'Path to the kernel binary.')
      ..addOption('drive', help: 'Path to a block device image file.')
      ..addOption('cmdline', help: 'Kernel command line string.');
  }

  final Logger _logger;

  @override
  String get description => 'Boot and run the RISC-V emulator.';

  @override
  String get name => 'run';

  @override
  Future<int> run() async {
    final config = ConfigResolver.resolve(_buildConfig());
    final emulator = Emulator(config);

    _logger.info(
      'Starting RISC-V emulator '
      '(${config.machineType}, '
      '${config.memorySizeMb}MB RAM)...',
    );

    final rawMode = _trySetRawMode();

    final sigintSub = ProcessSignal.sigint.watch().listen((_) {
      emulator.stop();
    });

    final stdinSub = stdin.listen(emulator.sendInput);

    final outputSub = emulator.output.listen((bytes) => stdout.add(bytes));

    try {
      _logger.info('Press Ctrl+C to exit.');
      await emulator.start();
    } finally {
      await outputSub.cancel();
      await sigintSub.cancel();
      await stdinSub.cancel();
      await emulator.dispose();
      if (rawMode) {
        _tryRestoreTerminal();
      }
    }

    return ExitCode.success.code;
  }

  bool _trySetRawMode() {
    try {
      if (!stdin.hasTerminal) return false;
      stdin
        ..echoMode = false
        ..lineMode = false;
      _applySttyFlags(_rawModeSttyArgs);
      return true;
    } on Object {
      return false;
    }
  }

  void _tryRestoreTerminal() {
    try {
      Process.runSync('sh', ['-c', 'stty sane < /dev/tty']);
    } on Object {
      // ignored
    }
  }

  void _applySttyFlags(List<String> flags) {
    Process.runSync('sh', ['-c', 'stty ${flags.join(' ')} < /dev/tty']);
  }

  static const _rawModeSttyArgs = [
    '-iexten',
    '-ixon',
    '-ixoff',
    '-icrnl',
    '-inlcr',
    '-igncr',
    '-opost',
  ];
  MachineConfig _buildConfig() {
    final configPath = argResults!['config'] as String?;
    if (configPath != null) {
      final loaded = ConfigLoader.loadFromFile(configPath);
      return MachineConfig(
        xlen: loaded.xlen,
        memorySizeMb: loaded.memorySizeMb,
        biosPath: loaded.biosPath,
        kernelPath: loaded.kernelPath,
        initrdPath: loaded.initrdPath,
        cmdLine: loaded.cmdLine,
        driveConfigs: loaded.driveConfigs,
        filesystemConfigs: loaded.filesystemConfigs,
        ethernetConfigs: loaded.ethernetConfigs,
        rtcLocalTime: loaded.rtcLocalTime,
        accel: loaded.accel,
      );
    }

    final memorySizeMb = int.parse(argResults!['memory'] as String);

    final drivePath = argResults!['drive'] as String?;
    final driveConfigs = <DriveConfig>[
      if (drivePath != null) DriveConfig(file: drivePath),
    ];

    return MachineConfig(
      memorySizeMb: memorySizeMb,
      biosPath: argResults!['bios'] as String?,
      kernelPath: argResults!['kernel'] as String?,
      cmdLine: argResults!['cmdline'] as String?,
      driveConfigs: driveConfigs,
    );
  }
}
