import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:yaml/yaml.dart';

/// A machine's YAML as written, before anything it names has been fetched.
///
/// Parsing and resolving are separate because only resolving knows where the
/// bytes live. On a host they are files on disk; in a browser they are
/// entries in a `.zip`, and there is no filesystem to resolve against at all.
/// Splitting them lets both readers share one list of keys, one version
/// check and one set of limits — which they previously did not, so a bundle
/// silently lost every key the second reader had not been taught.
///
/// Paths are kept exactly as written. What they are relative to is the
/// resolver's business.
class ConfigDocument {
  const ConfigDocument({
    required this.xlen,
    required this.memorySizeMb,
    required this.drives,
    required this.filesystems,
    required this.ethernets,
    this.bios,
    this.kernel,
    this.initrd,
    this.cmdLine,
    this.rtcLocalTime = false,
    this.useBuiltinSbi = false,
    this.accel,
  });

  /// Reads a document, or throws [ConfigException] when it cannot be read.
  factory ConfigDocument.parse(String yamlContent) {
    final doc = loadYaml(yamlContent);
    if (doc is! YamlMap) {
      throw const ConfigException('Config must be a YAML mapping');
    }

    final version = _getInt(doc, _Keys.version);
    if (version != null && version != supportedVersion) {
      throw ConfigException(
        'Unsupported config version: $version (expected $supportedVersion)',
      );
    }

    return ConfigDocument(
      xlen: _parseXlen(
        _getString(doc, _Keys.machine) ?? MachineConfig.defaultMachineType,
      ),
      memorySizeMb:
          _getInt(doc, _Keys.memorySize) ?? MachineConfig.defaultMemorySizeMb,
      bios: _getString(doc, _Keys.bios),
      kernel: _getString(doc, _Keys.kernel),
      initrd: _getString(doc, _Keys.initrd),
      cmdLine: _getString(doc, _Keys.cmdline),
      drives: _parseDrives(doc),
      filesystems: _parseFilesystems(doc),
      ethernets: _parseEthernets(doc),
      rtcLocalTime: _getBool(doc, _Keys.rtcLocalTime) ?? false,
      useBuiltinSbi: _getBool(doc, _Keys.useBuiltinSbi) ?? false,
      accel: _getString(doc, _Keys.accel),
    );
  }

  /// Register width the machine runs at.
  final Xlen xlen;

  /// Guest RAM in megabytes.
  final int memorySizeMb;

  /// Firmware image, as written.
  final String? bios;

  /// Kernel image, as written.
  final String? kernel;

  /// Initial ramdisk, as written.
  final String? initrd;

  /// Kernel command line.
  final String? cmdLine;

  /// Block devices, in declaration order.
  final List<DriveConfig> drives;

  /// VirtIO-9P shares, in declaration order.
  final List<FilesystemConfig> filesystems;

  /// Network devices, in declaration order.
  final List<EthernetConfig> ethernets;

  /// Whether the guest's clock follows local time rather than UTC.
  final bool rtcLocalTime;

  /// Whether to use the built-in SBI implementation instead of firmware.
  final bool useBuiltinSbi;

  /// Acceleration hint, passed through to the machine.
  final String? accel;

  /// The only config version this understands.
  static const supportedVersion = 1;

  static const _maxDrives = 4;
  static const _maxFilesystems = 4;
  static const _maxEthernets = 1;

  static Xlen _parseXlen(String machine) => switch (machine) {
    'riscv32' => Xlen.rv32,
    'riscv64' => Xlen.rv64,
    _ => throw ConfigException('Unsupported machine type: $machine'),
  };

  static List<DriveConfig> _parseDrives(YamlMap doc) => [
    for (var i = 0; i < _maxDrives; i++)
      if (_entry(doc, _Keys.drivePrefix, i) case final YamlMap drive)
        if (drive[_Keys.file] case final String file)
          DriveConfig(file: file, device: drive[_Keys.device] as String?),
  ];

  static List<FilesystemConfig> _parseFilesystems(YamlMap doc) => [
    for (var i = 0; i < _maxFilesystems; i++)
      if (_entry(doc, _Keys.fsPrefix, i) case final YamlMap fs)
        if (fs[_Keys.file] case final String file)
          FilesystemConfig(
            file: file,
            tag: fs[_Keys.tag] as String?,
            readOnly: fs[_Keys.readOnly] as bool? ?? false,
          ),
  ];

  static List<EthernetConfig> _parseEthernets(YamlMap doc) => [
    for (var i = 0; i < _maxEthernets; i++)
      if (_entry(doc, _Keys.ethPrefix, i) case final YamlMap eth)
        if (eth[_Keys.driver] case final String driver)
          EthernetConfig(
            driver: driver,
            ifname: eth[_Keys.ifname] as String?,
          ),
  ];

  static Object? _entry(YamlMap doc, String prefix, int index) =>
      doc['$prefix$index'];

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

/// The keys a machine config may carry. One list, so a second reader cannot
/// quietly know fewer of them.
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
  static const ethPrefix = 'eth';
  static const file = 'file';
  static const device = 'device';
  static const tag = 'tag';
  static const readOnly = 'readonly';
  static const driver = 'driver';
  static const ifname = 'ifname';
  static const rtcLocalTime = 'rtc_local_time';
  static const useBuiltinSbi = 'use_builtin_sbi';
  static const accel = 'accel';
}

/// Thrown when a configuration cannot be read.
class ConfigException implements Exception {
  /// Creates a [ConfigException] with the given [message].
  const ConfigException(this.message);

  /// A description of the error.
  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
