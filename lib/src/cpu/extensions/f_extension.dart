import 'package:dart_emu/src/cpu/cpu_state.dart';

class FExtension {
  FExtension({required this.state});

  final RiscVCpuState state;

  void executeFloat(int insn) {
    throw UnimplementedError('F extension');
  }
}
