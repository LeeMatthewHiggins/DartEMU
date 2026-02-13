import 'package:dart_emu/src/cpu/cpu_state.dart';

class DExtension {
  DExtension({required this.state});

  final RiscVCpuState state;

  void executeDouble(int insn) {
    throw UnimplementedError('D extension');
  }
}
