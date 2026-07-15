import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/device/file_block_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/net/user_net_device.dart';
import 'package:yaml/yaml.dart';

/// Loads [MachineConfig] from YAML configuration files or strings.
class ConfigLoader {
  const ConfigLoader._();

  static MachineConfig loadFromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException('Config file not found: $path');
    }
    final content = file.readAsStringSync();
    final baseDir = file.parent.path;
    return loadFromString(content, baseDir: baseDir);
  }

  static MachineConfig loadFromString(String yamlContent, {String? baseDir}) {
    final doc = loadYaml(yamlContent);
    if (doc is! YamlMap) {
      throw const ConfigException('Config must be a YAML mapping');
    }
    return _parseConfig(doc, baseDir);
  }

  static MachineConfig _parseConfig(YamlMap doc, String? baseDir) {
    _validateVersion(doc);

    final machineStr =
        _getString(doc, _Keys.machine) ?? MachineConfig.defaultMachineType;
    final xlen = _parseXlen(machineStr);
    final memorySizeMb =
        _getInt(doc, _Keys.memorySize) ?? MachineConfig.defaultMemorySizeMb;

    return MachineConfig(
      xlen: xlen,
      memorySizeMb: memorySizeMb,
      biosPath: _resolvePath(_getString(doc, _Keys.bios), baseDir),
      kernelPath: _resolvePath(_getString(doc, _Keys.kernel), baseDir),
      initrdPath: _resolvePath(_getString(doc, _Keys.initrd), baseDir),
      cmdLine: _getString(doc, _Keys.cmdline),
      driveConfigs: _parseDrives(doc, baseDir),
      filesystemConfigs: _parseFilesystems(doc),
      ethernetConfigs: _parseEthernets(doc),
      rtcLocalTime: _getBool(doc, _Keys.rtcLocalTime) ?? false,
      accel: _getString(doc, _Keys.accel),
    );
  }

  static String? _resolvePath(String? path, String? baseDir) {
    if (path == null || baseDir == null) return path;
    if (File(path).isAbsolute) return path;
    return '$baseDir${Platform.pathSeparator}$path';
  }

  static void _validateVersion(YamlMap doc) {
    final version = _getInt(doc, _Keys.version);
    if (version != null && version != _supportedVersion) {
      throw ConfigException(
        'Unsupported config version: $version '
        '(expected $_supportedVersion)',
      );
    }
  }

  static List<DriveConfig> _parseDrives(YamlMap doc, String? baseDir) {
    final drives = <DriveConfig>[];
    for (var i = 0; i < _maxDrives; i++) {
      final key = '${_Keys.drivePrefix}$i';
      final driveMap = doc[key];
      if (driveMap is YamlMap) {
        final file = driveMap[_Keys.file] as String?;
        if (file != null) {
          drives.add(
            DriveConfig(
              file: _resolvePath(file, baseDir) ?? file,
              device: driveMap[_Keys.device] as String?,
            ),
          );
        }
      }
    }
    return drives;
  }

  static List<EthernetConfig> _parseEthernets(YamlMap doc) {
    final ethConfigs = <EthernetConfig>[];
    for (var i = 0; i < _maxEthernets; i++) {
      final key = '${_Keys.ethPrefix}$i';
      final ethMap = doc[key];
      if (ethMap is YamlMap) {
        final driver = ethMap[_Keys.driver] as String?;
        if (driver != null) {
          ethConfigs.add(
            EthernetConfig(
              driver: driver,
              ifname: ethMap[_Keys.ifname] as String?,
            ),
          );
        }
      }
    }
    return ethConfigs;
  }

  static List<FilesystemConfig> _parseFilesystems(YamlMap doc) {
    final filesystems = <FilesystemConfig>[];
    for (var i = 0; i < _maxFilesystems; i++) {
      final key = '${_Keys.fsPrefix}$i';
      final fsMap = doc[key];
      if (fsMap is YamlMap) {
        final file = fsMap[_Keys.file] as String?;
        if (file != null) {
          filesystems.add(
            FilesystemConfig(file: file, tag: fsMap[_Keys.tag] as String?),
          );
        }
      }
    }
    return filesystems;
  }

  static String? _getString(YamlMap map, String key) {
    final value = map[key];
    return value is String ? value : null;
  }

  static int? _getInt(YamlMap map, String key) {
    final value = map[key];
    return value is int ? value : null;
  }

  static bool? _getBool(YamlMap map, String key) {
    final value = map[key];
    return value is bool ? value : null;
  }

  static Xlen _parseXlen(String machineStr) {
    return switch (machineStr) {
      'riscv32' => Xlen.rv32,
      'riscv64' => Xlen.rv64,
      _ => throw ConfigException('Unsupported machine type: $machineStr'),
    };
  }

  static const _supportedVersion = 1;
  static const _maxDrives = 4;
  static const _maxFilesystems = 4;
  static const _maxEthernets = 1;
}

class _Keys {
  static const version = 'version';
  static const machine = 'machine';
  static const memorySize = 'memory_size';
  static const bios = 'bios';
  static const kernel = 'kernel';
  static const initrd = 'initrd';
  static const cmdline = 'cmdline';
  static const drivePrefix = 'drive';
  static const fsPrefix = 'fs';
  static const file = 'file';
  static const device = 'device';
  static const tag = 'tag';
  static const ethPrefix = 'eth';
  static const driver = 'driver';
  static const ifname = 'ifname';
  static const rtcLocalTime = 'rtc_local_time';
  static const accel = 'accel';
}

/// Resolves file-path references in a [MachineConfig] to in-memory data
/// and concrete block device instances.
///
/// This class uses `dart:io` and is intended for CLI or desktop contexts
/// where file system access is available.
class ConfigResolver {
  const ConfigResolver._();

  static MachineConfig resolve(MachineConfig config) {
    return config.copyWith(
      biosData: config.biosData ?? _readFileOrNull(config.biosPath),
      kernelData: config.kernelData ?? _readFileOrNull(config.kernelPath),
      initrdData: config.initrdData ?? _readFileOrNull(config.initrdPath),
      blockDevices: [
        ...config.blockDevices,
        ...config.driveConfigs.map((drive) => FileBlockDevice.open(drive.file)),
      ],
      ethDevices: [
        ...config.ethDevices,
        ...config.ethernetConfigs.map(_resolveEthernet),
      ],
    );
  }

  static EthernetDevice _resolveEthernet(EthernetConfig eth) {
    return switch (eth.driver) {
      'user' => UserNetDevice(),
      _ => throw ConfigException('Unsupported ethernet driver: ${eth.driver}'),
    };
  }

  static Uint8List? _readFileOrNull(String? path) {
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException('Image file not found: $path');
    }
    return file.readAsBytesSync();
  }
}

/// Exception thrown when machine configuration parsing fails.
class ConfigException implements Exception {
  const ConfigException(this.message);
  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
