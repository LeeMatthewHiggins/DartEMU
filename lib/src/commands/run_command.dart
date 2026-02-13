import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_emu/src/io/console_adapter.dart';
import 'package:dart_emu/src/machine/config_loader.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';
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
      ..addOption(
        'bios',
        help: 'Path to the BIOS/bootloader binary.',
      )
      ..addOption(
        'kernel',
        help: 'Path to the kernel binary.',
      )
      ..addOption(
        'drive',
        help: 'Path to a block device image file.',
      )
      ..addOption(
        'cmdline',
        help: 'Kernel command line string.',
      );
  }

  final Logger _logger;

  @override
  String get description => 'Boot and run the RISC-V emulator.';

  @override
  String get name => 'run';

  @override
  Future<int> run() async {
    final consoleAdapter = ConsoleAdapter();
    final config = _buildConfig(consoleAdapter);

    _logger.info(
      'Starting RISC-V emulator '
      '(${config.machineType}, '
      '${config.memorySizeMb}MB RAM)...',
    );

    final machine = RiscVMachine.fromConfig(config);

    _logger.info(
      'Machine created: '
      '${machine.memMap.ranges.length} memory regions',
    );

    await _runMachine(machine, consoleAdapter);

    return ExitCode.success.code;
  }

  Future<void> _runMachine(
    RiscVMachine machine,
    ConsoleAdapter consoleAdapter,
  ) async {
    final isTerminal = stdin.hasTerminal;
    if (isTerminal) {
      stdin
        ..echoMode = false
        ..lineMode = false;
    }

    final stdinSub = stdin.listen(consoleAdapter.feedInput);

    try {
      while (!machine.cpu.powerDown) {
        machine.step(_cyclesPerStep);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await stdinSub.cancel();
      if (isTerminal) {
        stdin
          ..echoMode = true
          ..lineMode = true;
      }
    }
  }

  MachineConfig _buildConfig(ConsoleAdapter consoleAdapter) {
    final configPath = argResults!['config'] as String?;
    if (configPath != null) {
      final loaded = ConfigLoader.loadFromFile(configPath);
      return MachineConfig(
        machineType: loaded.machineType,
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
        console: consoleAdapter,
      );
    }

    final memorySizeMb = int.parse(
      argResults!['memory'] as String,
    );

    return MachineConfig(
      memorySizeMb: memorySizeMb,
      biosPath: argResults!['bios'] as String?,
      kernelPath: argResults!['kernel'] as String?,
      cmdLine: argResults!['cmdline'] as String?,
      console: consoleAdapter,
    );
  }

  static const _cyclesPerStep = 500000;
}
