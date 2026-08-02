import 'dart:io';
import 'dart:typed_data';

import 'package:dart_emu/src/device/ethernet_device.dart';
import 'package:dart_emu/src/device/file_block_device.dart';
import 'package:dart_emu/src/device/virtio/ninep/ninep_directory_backend.dart';
import 'package:dart_emu/src/machine/config_document.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/net/user_net_device.dart';

export 'package:dart_emu/src/machine/config_document.dart'
    show ConfigDocument, ConfigException;

/// Loads [MachineConfig] from YAML configuration files or strings.
///
/// Reading the YAML is [ConfigDocument]'s job; this resolves what the
/// document names against the filesystem, which is the only part that needs
/// `dart:io` and therefore the only part a browser cannot use.
class ConfigLoader {
  const ConfigLoader._();

  /// Loads a config, resolving relative paths against the file's own
  /// directory rather than the working directory.
  static MachineConfig loadFromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException('Config file not found: $path');
    }
    return loadFromString(file.readAsStringSync(), baseDir: file.parent.path);
  }

  /// Loads a config from YAML text, resolving relative paths against
  /// [baseDir] when one is given.
  static MachineConfig loadFromString(String yamlContent, {String? baseDir}) =>
      resolve(ConfigDocument.parse(yamlContent), baseDir: baseDir);

  /// Turns a parsed document into a machine, with every path made absolute.
  static MachineConfig resolve(ConfigDocument doc, {String? baseDir}) {
    return MachineConfig(
      xlen: doc.xlen,
      memorySizeMb: doc.memorySizeMb,
      biosPath: _resolvePath(doc.bios, baseDir),
      kernelPath: _resolvePath(doc.kernel, baseDir),
      initrdPath: _resolvePath(doc.initrd, baseDir),
      cmdLine: doc.cmdLine,
      driveConfigs: [
        for (final drive in doc.drives)
          DriveConfig(
            file: _resolvePath(drive.file, baseDir) ?? drive.file,
            device: drive.device,
          ),
      ],
      // Shares are directories the host serves live, so they are resolved
      // where they are opened rather than here.
      filesystemConfigs: doc.filesystems,
      ethernetConfigs: doc.ethernets,
      rtcLocalTime: doc.rtcLocalTime,
      useBuiltinSbi: doc.useBuiltinSbi,
      accel: doc.accel,
    );
  }

  static String? _resolvePath(String? path, String? baseDir) {
    if (path == null || baseDir == null) return path;
    if (File(path).isAbsolute) return path;
    return '$baseDir${Platform.pathSeparator}$path';
  }
}

/// Turns the paths and drivers a config names into open devices.
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
      // Without this a configured `fs0:` was parsed and then dropped, so a
      // share declared in YAML never reached the guest.
      sharedFolders: [
        ...config.sharedFolders,
        ..._resolveFilesystems(config.filesystemConfigs),
      ],
    );
  }

  static Iterable<NinePShare> _resolveFilesystems(
    List<FilesystemConfig> filesystems,
  ) sync* {
    for (var i = 0; i < filesystems.length; i++) {
      final fs = filesystems[i];
      yield NinePShare(
        tag: fs.tag ?? 'fs$i',
        backend: createDirectoryNinePBackend(fs.file, readOnly: fs.readOnly),
      );
    }
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
