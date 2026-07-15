import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_emu/dart_emu.dart';
import 'package:yaml/yaml.dart';

class _Keys {
  static const version = 'version';
  static const machine = 'machine';
  static const memorySize = 'memory_size';
  static const bios = 'bios';
  static const kernel = 'kernel';
  static const initrd = 'initrd';
  static const cmdline = 'cmdline';
  static const drivePrefix = 'drive';
  static const ethPrefix = 'eth';
  static const file = 'file';
  static const driver = 'driver';
  static const rtcLocalTime = 'rtc_local_time';
}

class _Limits {
  static const maxDrives = 4;
  static const maxEthernets = 1;
  static const supportedVersion = 1;
}

/// Loads a [MachineConfig] from a zip archive containing a YAML config
/// and its referenced binary files.
///
/// This loader is platform-independent and works on both web and desktop
/// since everything is resolved from in-memory archive entries.
class ZipConfigLoader {
  const ZipConfigLoader._();

  /// Parses [zipBytes] and returns a fully resolved [MachineConfig].
  ///
  /// The archive must contain exactly one `.yaml` or `.yml` file.
  /// All paths referenced in the config (bios, kernel, drives) are
  /// resolved against entries in the archive.
  static MachineConfig load(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final configEntry = _findConfigEntry(archive);
    final yamlContent = String.fromCharCodes(configEntry.content as List<int>);
    final configDir = _parentDir(configEntry.name);

    final doc = loadYaml(yamlContent);
    if (doc is! YamlMap) {
      throw const ZipConfigException('Config must be a YAML mapping');
    }

    return _resolve(doc, archive, configDir);
  }

  static ArchiveFile _findConfigEntry(Archive archive) {
    final configs = archive.files.where((f) => f.isFile && _isYaml(f.name));
    if (configs.isEmpty) {
      throw const ZipConfigException(
        'No .yaml or .yml config file found in archive',
      );
    }
    if (configs.length > 1) {
      throw const ZipConfigException(
        'Archive contains multiple YAML files — expected exactly one',
      );
    }
    return configs.single;
  }

  static MachineConfig _resolve(
    YamlMap doc,
    Archive archive,
    String configDir,
  ) {
    _validateVersion(doc);

    final machineStr =
        _getString(doc, _Keys.machine) ?? MachineConfig.defaultMachineType;
    final xlen = _parseXlen(machineStr);
    final memorySizeMb =
        _getInt(doc, _Keys.memorySize) ?? MachineConfig.defaultMemorySizeMb;

    return MachineConfig(
      xlen: xlen,
      memorySizeMb: memorySizeMb,
      biosData: _readArchiveFile(
        archive,
        configDir,
        _getString(doc, _Keys.bios),
      ),
      kernelData: _readArchiveFile(
        archive,
        configDir,
        _getString(doc, _Keys.kernel),
      ),
      initrdData: _readArchiveFile(
        archive,
        configDir,
        _getString(doc, _Keys.initrd),
      ),
      cmdLine: _getString(doc, _Keys.cmdline),
      blockDevices: _resolveDrives(doc, archive, configDir),
      ethDevices: _resolveEthernets(doc),
      rtcLocalTime: _getBool(doc, _Keys.rtcLocalTime) ?? false,
    );
  }

  static List<BlockDevice> _resolveDrives(
    YamlMap doc,
    Archive archive,
    String configDir,
  ) {
    final drives = <BlockDevice>[];
    for (var i = 0; i < _Limits.maxDrives; i++) {
      final driveMap = doc['${_Keys.drivePrefix}$i'];
      if (driveMap is YamlMap) {
        final file = driveMap[_Keys.file] as String?;
        if (file != null) {
          final data = _readArchiveFile(archive, configDir, file);
          if (data != null) {
            drives.add(MemoryBlockDevice.fromData(data));
          }
        }
      }
    }
    return drives;
  }

  static List<EthernetDevice> _resolveEthernets(YamlMap doc) {
    final devices = <EthernetDevice>[];
    for (var i = 0; i < _Limits.maxEthernets; i++) {
      final ethMap = doc['${_Keys.ethPrefix}$i'];
      if (ethMap is YamlMap) {
        final driver = ethMap[_Keys.driver] as String?;
        if (driver == 'user') {
          devices.add(UserNetDevice());
        }
      }
    }
    return devices;
  }

  static Uint8List? _readArchiveFile(
    Archive archive,
    String configDir,
    String? relativePath,
  ) {
    if (relativePath == null) return null;

    final fullPath = configDir.isEmpty
        ? relativePath
        : '$configDir/$relativePath';

    final entry = archive.files.cast<ArchiveFile?>().firstWhere(
      (f) => f!.isFile && (f.name == fullPath || f.name == relativePath),
      orElse: () => null,
    );

    if (entry == null) {
      throw ZipConfigException('File not found in archive: $relativePath');
    }

    return entry.content;
  }

  static String _parentDir(String path) {
    final lastSlash = path.lastIndexOf('/');
    return lastSlash < 0 ? '' : path.substring(0, lastSlash);
  }

  static bool _isYaml(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('/')) {
      final fileName = lower.substring(lower.lastIndexOf('/') + 1);
      return fileName.endsWith('.yaml') || fileName.endsWith('.yml');
    }
    return lower.endsWith('.yaml') || lower.endsWith('.yml');
  }

  static void _validateVersion(YamlMap doc) {
    final version = _getInt(doc, _Keys.version);
    if (version != null && version != _Limits.supportedVersion) {
      throw ZipConfigException(
        'Unsupported config version: $version '
        '(expected ${_Limits.supportedVersion})',
      );
    }
  }

  static Xlen _parseXlen(String machineStr) {
    return switch (machineStr) {
      'riscv32' => Xlen.rv32,
      'riscv64' => Xlen.rv64,
      _ => throw ZipConfigException('Unsupported machine type: $machineStr'),
    };
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
}

/// Exception thrown when zip-based configuration loading fails.
class ZipConfigException implements Exception {
  /// Creates a [ZipConfigException] with the given [message].
  const ZipConfigException(this.message);

  /// A description of the error.
  final String message;

  @override
  String toString() => 'ZipConfigException: $message';
}
