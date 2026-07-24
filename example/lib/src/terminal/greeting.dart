import 'package:dart_emu/dart_emu.dart';

/// Builds the DartEMU banner shown in the terminal before the guest
/// starts producing output.
///
/// Deliberately **ASCII-only**: Unicode box-drawing characters render as
/// tofu in some terminal font fallbacks, and this demo is embedded in
/// blog iframes and viewed on arbitrary machines. The banner is also
/// kept narrow so it does not wrap on a phone. Rows are padded to a
/// fixed inner width and colour is applied to whole lines, so escape
/// codes never affect alignment.
String dartEmuGreeting(Xlen xlen) {
  final is64 = xlen == Xlen.rv64;
  final arch = is64 ? 'rv64' : 'rv32';
  final toolchain = is64 ? 'cc (TCC) ready' : 'busybox userland';

  final lines = <String>[
    '',
    _cyan('  ${_rule()}'),
    _cyan('  ${_row('')}'),
    _cyan('  ${_row('  D A R T E M U')}'),
    _cyan('  ${_row('  RISC-V system emulator in Dart')}'),
    _cyan('  ${_row('')}'),
    _cyan('  ${_rule()}'),
    '',
    _dim('   guest: $arch | Linux | $toolchain'),
    _dim('   booting...'),
    '',
  ];

  // Terminals need CR+LF, not bare LF.
  return '${lines.join('\r\n')}\r\n';
}

String _rule() => '+${'-' * _Banner.innerWidth}+';

/// Pads [content] to the banner's inner width and frames it.
String _row(String content) {
  final padding = _Banner.innerWidth - content.length;
  return '|$content${' ' * (padding < 0 ? 0 : padding)}|';
}

String _cyan(String line) => '${_Ansi.cyan}$line${_Ansi.reset}';

String _dim(String line) => '${_Ansi.dim}$line${_Ansi.reset}';

class _Banner {
  static const innerWidth = 38;
}

class _Ansi {
  static const reset = '\x1b[0m';
  static const dim = '\x1b[2m';
  static const cyan = '\x1b[36m';
}
