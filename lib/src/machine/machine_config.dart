import 'dart:typed_data';

import 'package:dart_emu/src/device/block_device.dart';
import 'package:dart_emu/src/device/character_device.dart';
import 'package:dart_emu/src/device/ethernet_device.dart';

class MachineConfig {
  MachineConfig({
    this.machineType = defaultMachineType,
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

  final String machineType;
  final int memorySizeMb;

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

  static const _bytesPerMb = 1024 * 1024;
  static const defaultMemorySizeMb = 256;
  static const defaultMachineType = 'riscv64';
}

class FilesystemConfig {
  const FilesystemConfig({
    required this.file,
    this.tag,
  });

  final String file;
  final String? tag;
}

class DriveConfig {
  const DriveConfig({
    required this.file,
    this.device,
  });

  final String file;
  final String? device;
}

class EthernetConfig {
  const EthernetConfig({
    required this.driver,
    this.ifname,
  });

  final String driver;
  final String? ifname;
}
