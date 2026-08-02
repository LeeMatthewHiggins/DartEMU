import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_emu/dart_emu.dart';

/// Loads a [MachineConfig] from a zip archive containing a YAML config
/// and its referenced files.
///
/// Works on web as well as desktop, because everything the config names is
/// resolved from archive entries rather than from a filesystem — which on
/// web does not exist.
///
/// Reading the YAML is [ConfigDocument]'s job, shared with the file-based
/// loader. This used to parse the YAML itself and had drifted to knowing
/// seven fewer keys, so a bundle declaring a share, a device name or an
/// interface name booted a machine quietly missing them.
class ZipConfigLoader {
  const ZipConfigLoader._();

  /// Parses [zipBytes] and returns a fully resolved [MachineConfig].
  ///
  /// The archive must contain exactly one `.yaml` or `.yml` file. Paths in
  /// it resolve against that file's own directory in the archive.
  static MachineConfig load(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final entry = _findConfigEntry(archive);
    final configDir = _parentDir(entry.name);

    final ConfigDocument doc;
    try {
      doc = ConfigDocument.parse(utf8.decode(entry.content as List<int>));
    } on ConfigException catch (e) {
      // One exception type for anything wrong with a bundle, so a caller
      // does not have to know which layer read which part of it.
      throw ZipConfigException(e.message);
    }

    return MachineConfig(
      xlen: doc.xlen,
      memorySizeMb: doc.memorySizeMb,
      biosData: _read(archive, configDir, doc.bios),
      kernelData: _read(archive, configDir, doc.kernel),
      initrdData: _read(archive, configDir, doc.initrd),
      cmdLine: doc.cmdLine,
      blockDevices: [
        for (final drive in doc.drives)
          MemoryBlockDevice.fromData(_read(archive, configDir, drive.file)!),
      ],
      sharedFolders: _shares(archive, configDir, doc.filesystems),
      ethDevices: [for (final eth in doc.ethernets) _ethernet(eth)],
      rtcLocalTime: doc.rtcLocalTime,
      useBuiltinSbi: doc.useBuiltinSbi,
      accel: doc.accel,
    );
  }

  /// Serves a directory of archive entries to the guest over 9P.
  ///
  /// A bundle is a fixed set of bytes, so the share is held in memory. Writes
  /// live as long as the machine does and are gone with it, which is the most
  /// a `.zip` can honestly offer.
  static List<NinePShare> _shares(
    Archive archive,
    String configDir,
    List<FilesystemConfig> filesystems,
  ) {
    final shares = <NinePShare>[];
    for (var i = 0; i < filesystems.length; i++) {
      final fs = filesystems[i];
      final root = _join(configDir, fs.file);
      final backend = MemoryNinePBackend();

      var found = false;
      for (final file in archive.files) {
        if (!file.isFile || !file.name.startsWith('$root/')) continue;
        found = true;
        final guestPath = file.name.substring(root.length);
        _ensureParents(backend, guestPath);
        backend.addFile(guestPath, file.content as List<int>);
      }
      if (!found) {
        throw ZipConfigException(
          'The archive has no directory "${fs.file}" to share',
        );
      }
      shares.add(NinePShare(tag: fs.tag ?? 'fs$i', backend: backend));
    }
    return shares;
  }

  /// The backend stores files by path, but a directory has to exist before
  /// the guest can walk into it.
  static void _ensureParents(MemoryNinePBackend backend, String guestPath) {
    final parts = guestPath.split('/')..removeLast();
    var path = '';
    for (final part in parts) {
      if (part.isEmpty) continue;
      path = '$path/$part';
      backend.addDirectory(path);
    }
  }

  static EthernetDevice _ethernet(EthernetConfig eth) => switch (eth.driver) {
    'user' => UserNetDevice(),
    _ => throw ZipConfigException('Unsupported ethernet driver: ${eth.driver}'),
  };

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

  static Uint8List? _read(Archive archive, String configDir, String? path) {
    if (path == null) return null;
    final full = _join(configDir, path);

    final entry = archive.files.cast<ArchiveFile?>().firstWhere(
      (f) => f!.isFile && (f.name == full || f.name == path),
      orElse: () => null,
    );
    if (entry == null) {
      throw ZipConfigException('File not found in archive: $path');
    }
    return entry.content;
  }

  static String _join(String dir, String path) =>
      dir.isEmpty ? path : '$dir/$path';

  static String _parentDir(String path) {
    final lastSlash = path.lastIndexOf('/');
    return lastSlash < 0 ? '' : path.substring(0, lastSlash);
  }

  static bool _isYaml(String name) {
    final lower = name.toLowerCase();
    final fileName = lower.contains('/')
        ? lower.substring(lower.lastIndexOf('/') + 1)
        : lower;
    return fileName.endsWith('.yaml') || fileName.endsWith('.yml');
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
