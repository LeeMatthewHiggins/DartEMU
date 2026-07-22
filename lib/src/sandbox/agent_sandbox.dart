import 'dart:convert';

import 'package:dart_emu/src/device/memory_block_device.dart';
import 'package:dart_emu/src/machine/machine_config.dart';
import 'package:dart_emu/src/machine/riscv_machine.dart';
import 'package:dart_emu/src/sandbox/exec_result.dart';
import 'package:dart_emu/src/sandbox/sandbox_config.dart';
import 'package:dart_emu/src/sandbox/sandbox_console.dart';

/// Thrown when the guest fails to reach an expected state in time.
class SandboxTimeoutException implements Exception {
  SandboxTimeoutException(this.message, this.consoleTail);

  final String message;

  /// Recent console output, for diagnostics.
  final String consoleTail;

  @override
  String toString() =>
      'SandboxTimeoutException: $message\nlast console output:\n$consoleTail';
}

/// A disposable Linux sandbox for running agent-authored commands.
///
/// Boots a fresh, fully-interpreted RISC-V guest from in-memory images,
/// runs shell commands with captured stdout, exit codes, and per-command
/// wall-clock and instruction budgets, and exchanges files with the
/// guest. The guest never executes a host instruction and (by default)
/// has no network, so the whole VM is a throwaway isolation boundary.
///
/// ```dart
/// final sandbox = AgentSandbox(config);
/// await sandbox.boot();
/// final r = await sandbox.exec('echo hello');
/// print(r.stdout); // hello
/// await sandbox.dispose();
/// ```
///
/// The exec loop drives emulation on the current isolate, yielding to
/// the event loop periodically so it does not starve other work. A
/// Flutter UI that needs frame-paced execution should drive the
/// lower-level `Emulator` from a `Ticker` instead.
class AgentSandbox {
  AgentSandbox(this.config);

  /// The configuration this sandbox was created with.
  final SandboxConfig config;

  final SandboxConsole _console = SandboxConsole();
  RiscVMachine? _machine;
  var _booted = false;
  var _sequence = 0;

  /// Whether [boot] has completed and the sandbox is ready for [exec].
  bool get ready => _booted;

  /// Total guest instructions retired since boot.
  int get instructionsRetired => _machine?.cpu.state.instructionCounter ?? 0;

  /// Boots the guest and waits for its first shell prompt.
  ///
  /// Boots from a fresh copy of the rootfs image, so repeated sandboxes
  /// built from the same [SandboxConfig] each start pristine.
  Future<void> boot() async {
    if (_machine != null) {
      throw StateError('Sandbox already booted');
    }
    _machine = RiscVMachine.fromConfig(
      MachineConfig(
        xlen: config.xlen,
        memorySizeMb: config.memorySizeMb,
        biosData: config.biosData,
        kernelData: config.kernelData,
        cmdLine: config.cmdLine,
        console: _console,
        blockDevices: [MemoryBlockDevice.fromData(config.rootfsData)],
        ethDevices: config.ethDevices,
      ),
    );
    _console.beginWait(config.shellPrompt);
    await _drive(
      timeout: config.bootTimeout,
      onReady: () => _booted = true,
      what: 'boot',
    );
    // Quiet the interactive shell so everything between exec markers is
    // pure command output: no tty echo of the fed command, no prompt,
    // no line-continuation prompt.
    await exec("stty -echo 2>/dev/null; PS1=''; PS2=''");
  }

  /// Runs [command] in the guest shell and returns its result.
  ///
  /// Captures combined stdout/stderr and the exit status. The run stops
  /// early if [timeout] elapses or the guest retires more than
  /// [maxInstructions]; both default to the values in [SandboxConfig].
  Future<ExecResult> exec(
    String command, {
    Duration? timeout,
    int? maxInstructions,
  }) {
    _ensureReady();
    final seq = _sequence++;

    // The guest computes the marker digits with `$((seq))`, so the tty
    // echo of the command line contains `$((7))` and never the literal
    // `__SBX*_7__` the console scans for. Markers are newline-separated
    // (not `;`-joined) so a here-doc terminator inside [command] sits
    // alone on its line and closes correctly.
    final beginLiteral = '__SBXBEG_${seq}__';
    final endLiteral = '__SBXEND_${seq}__';
    final line =
        'printf \'%s\\n\' "__SBXBEG_\$(($seq))__"\n'
        '$command\n'
        'printf \'%s %s\\n\' "__SBXEND_\$(($seq))__" "\$?"\n';

    _console
      ..beginWait(endLiteral)
      ..feedInput(utf8.encode(line));

    return _driveExec(
      beginLiteral: beginLiteral,
      timeout: timeout ?? config.defaultTimeout,
      maxInstructions: maxInstructions ?? config.defaultMaxInstructions,
    );
  }

  /// Releases guest resources. The sandbox cannot be reused afterwards.
  Future<void> dispose() async {
    _machine?.cpu.state.shutDown = true;
    _machine = null;
    _booted = false;
  }

  /// Sends a marker-delimited command that the guest computes at runtime
  /// so the tty echo of the command line never contains the literal
  /// marker, then drives emulation until the end marker prints.
  Future<ExecResult> _driveExec({
    required String beginLiteral,
    required Duration timeout,
    int? maxInstructions,
  }) async {
    final stopwatch = Stopwatch()..start();
    final startInstructions = _machine!.cpu.state.instructionCounter;
    var iterations = 0;

    while (!_console.markerFound()) {
      _machine!.step(_cyclesPerStep);
      final retired =
          _machine!.cpu.state.instructionCounter - startInstructions;

      if (maxInstructions != null && retired > maxInstructions) {
        return _abort(ExecOutcome.budgetExceeded, retired, stopwatch.elapsed);
      }
      if (stopwatch.elapsed >= timeout) {
        return _abort(ExecOutcome.timedOut, retired, stopwatch.elapsed);
      }
      if (_machine!.cpu.state.shutDown) {
        return _partial(ExecOutcome.timedOut, retired, stopwatch.elapsed);
      }
      if (++iterations % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    stopwatch.stop();
    final retired = _machine!.cpu.state.instructionCounter - startInstructions;
    return ExecResult(
      outcome: ExecOutcome.completed,
      stdout: _extractStdout(beginLiteral),
      exitCode: _parseExitCode(_console.markerTail()),
      instructions: retired,
      wallTime: stopwatch.elapsed,
    );
  }

  ExecResult _partial(ExecOutcome outcome, int retired, Duration wall) =>
      ExecResult(
        outcome: outcome,
        stdout: _console.tail(),
        exitCode: null,
        instructions: retired,
        wallTime: wall,
      );

  /// Captures the partial result, then interrupts the still-running
  /// guest command (Ctrl-C) and resyncs so the sandbox stays usable for
  /// the next [exec]. If the guest cannot be brought back to an idle
  /// shell, marks the sandbox not-ready.
  Future<ExecResult> _abort(
    ExecOutcome outcome,
    int retired,
    Duration wall,
  ) async {
    final result = _partial(outcome, retired, wall);
    await _recover();
    return result;
  }

  Future<void> _recover() async {
    final seq = _sequence++;
    final endLiteral = '__SBXEND_${seq}__';
    _console
      ..beginWait(endLiteral)
      // Ctrl-C aborts the foreground command; the printf then confirms
      // the shell is reading again.
      ..feedInput([_ctrlC])
      ..feedInput(utf8.encode('printf \'%s\\n\' "__SBXEND_\$(($seq))__"\n'));

    final stopwatch = Stopwatch()..start();
    var iterations = 0;
    while (!_console.markerFound()) {
      _machine!.step(_cyclesPerStep);
      if (stopwatch.elapsed >= _recoverTimeout ||
          _machine!.cpu.state.shutDown) {
        _booted = false;
        return;
      }
      if (++iterations % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  Future<void> _drive({
    required Duration timeout,
    required void Function() onReady,
    required String what,
  }) async {
    final stopwatch = Stopwatch()..start();
    var iterations = 0;
    while (!_console.markerFound()) {
      _machine!.step(_cyclesPerStep);
      if (stopwatch.elapsed >= timeout) {
        throw SandboxTimeoutException(
          '$what did not complete within ${timeout.inSeconds}s',
          _console.tail(),
        );
      }
      if (++iterations % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    onReady();
  }

  /// Pulls the real command output from between the begin marker line
  /// and the end marker, discarding the echoed command line.
  String _extractStdout(String beginLiteral) {
    final phase = _console.phaseOutput().replaceAll('\r\n', '\n');
    final beginAt = phase.indexOf(beginLiteral);
    if (beginAt < 0) return _stripTrailingNewline(phase);
    final afterBegin = phase.indexOf('\n', beginAt);
    if (afterBegin < 0) return '';
    return _stripTrailingNewline(phase.substring(afterBegin + 1));
  }

  String _stripTrailingNewline(String text) =>
      text.endsWith('\n') ? text.substring(0, text.length - 1) : text;

  int? _parseExitCode(String markerTail) => int.tryParse(markerTail.trim());

  /// Debug-only: raw console text of the most recent phase.
  String get debugPhaseOutput => _console.phaseOutput();

  void _ensureReady() {
    if (!_booted) {
      throw StateError('Sandbox not booted; call boot() first');
    }
  }

  static const _cyclesPerStep = 50000;
  static const _yieldEvery = 8;
  static const _ctrlC = 0x03;
  static const _recoverTimeout = Duration(seconds: 10);
}
