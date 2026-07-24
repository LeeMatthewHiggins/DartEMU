import 'dart:typed_data';

import 'package:dart_emu/src/device/block_device.dart';
import 'package:dart_emu/src/device/character_device.dart';
import 'package:dart_emu/src/device/ethernet_device.dart';

/// Register width for the RISC-V CPU.
enum Xlen {
  rv32(32),
  rv64(64);

  const Xlen(this.value);

  /// The register width in bits.
  final int value;
}

/// Configuration for a RISC-V virtual machine instance.
///
/// Supports both file-path based loading (for CLI) and in-memory
/// byte data (for Flutter or embedded use).
class MachineConfig {
  MachineConfig({
    this.xlen = Xlen.rv64,
    this.memorySizeMb = defaultMemorySizeMb,
    this.console,
    this.blockDevices = const [],
    this.ethDevices = const [],
    this.driveConfigs = const [],
    this.filesystemConfigs = const [],
    this.ethernetConfigs = const [],
    this.cmdLine,
    this.biosPath,
    this.kernelPath,
    this.initrdPath,
    this.biosData,
    this.kernelData,
    this.initrdData,
    this.rtcLocalTime = false,
    this.accel,
  });

  final Xlen xlen;
  final int memorySizeMb;

  String get machineType => switch (xlen) {
    Xlen.rv32 => 'riscv32',
    Xlen.rv64 => 'riscv64',
  };

  final CharacterDevice? console;
  final List<BlockDevice> blockDevices;
  final List<EthernetDevice> ethDevices;

  final List<DriveConfig> driveConfigs;
  final List<FilesystemConfig> filesystemConfigs;
  final List<EthernetConfig> ethernetConfigs;

  final String? cmdLine;
  final String? biosPath;
  final String? kernelPath;
  final String? initrdPath;
  final Uint8List? biosData;
  final Uint8List? kernelData;
  final Uint8List? initrdData;
  final bool rtcLocalTime;
  final String? accel;

  int get memorySizeBytes => memorySizeMb * _bytesPerMb;

  MachineConfig copyWith({
    Xlen? xlen,
    int? memorySizeMb,
    CharacterDevice? console,
    List<BlockDevice>? blockDevices,
    List<EthernetDevice>? ethDevices,
    List<DriveConfig>? driveConfigs,
    List<FilesystemConfig>? filesystemConfigs,
    List<EthernetConfig>? ethernetConfigs,
    String? cmdLine,
    String? biosPath,
    String? kernelPath,
    String? initrdPath,
    Uint8List? biosData,
    Uint8List? kernelData,
    Uint8List? initrdData,
    bool? rtcLocalTime,
    String? accel,
  }) {
    return MachineConfig(
      xlen: xlen ?? this.xlen,
      memorySizeMb: memorySizeMb ?? this.memorySizeMb,
      console: console ?? this.console,
      blockDevices: blockDevices ?? this.blockDevices,
      ethDevices: ethDevices ?? this.ethDevices,
      driveConfigs: driveConfigs ?? this.driveConfigs,
      filesystemConfigs: filesystemConfigs ?? this.filesystemConfigs,
      ethernetConfigs: ethernetConfigs ?? this.ethernetConfigs,
      cmdLine: cmdLine ?? this.cmdLine,
      biosPath: biosPath ?? this.biosPath,
      kernelPath: kernelPath ?? this.kernelPath,
      initrdPath: initrdPath ?? this.initrdPath,
      biosData: biosData ?? this.biosData,
      kernelData: kernelData ?? this.kernelData,
      initrdData: initrdData ?? this.initrdData,
      rtcLocalTime: rtcLocalTime ?? this.rtcLocalTime,
      accel: accel ?? this.accel,
    );
  }

  static const int _bytesPerMb = 1024 * 1024;
  static const defaultMemorySizeMb = 256;
  static const defaultMachineType = 'riscv64';
  static const Xlen defaultXlen = Xlen.rv64;
}

/// Configuration for a VirtIO 9P shared filesystem.
class FilesystemConfig {
  const FilesystemConfig({required this.file, this.tag});

  final String file;
  final String? tag;
}

/// Configuration for a VirtIO block device backed by a file.
class DriveConfig {
  const DriveConfig({required this.file, this.device});

  final String file;
  final String? device;
}

/// Configuration for a VirtIO network device.
class EthernetConfig {
  const EthernetConfig({required this.driver, this.ifname});

  final String driver;
  final String? ifname;
}
