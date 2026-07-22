/// How a sandboxed command run terminated.
enum ExecOutcome {
  /// The command ran to completion and reported an exit status.
  completed,

  /// The wall-clock timeout elapsed before the command finished.
  timedOut,

  /// The guest instruction budget was exhausted before completion.
  budgetExceeded,
}

/// The result of running a command inside an `AgentSandbox`.
class ExecResult {
  ExecResult({
    required this.outcome,
    required this.stdout,
    required this.exitCode,
    required this.instructions,
    required this.wallTime,
  });

  /// How the run terminated.
  final ExecOutcome outcome;

  /// Combined stdout+stderr text captured from the guest console.
  ///
  /// On a timeout or budget overrun this holds whatever was produced
  /// before the run was abandoned.
  final String stdout;

  /// The command's exit status, or `null` if it did not complete.
  final int? exitCode;

  /// Guest instructions retired while the command ran.
  final int instructions;

  /// Host wall-clock time the command took.
  final Duration wallTime;

  /// Whether the command completed with a zero exit status.
  bool get succeeded => outcome == ExecOutcome.completed && exitCode == 0;

  @override
  String toString() =>
      'ExecResult(${outcome.name}, exit=$exitCode, '
      '${instructions ~/ 1000}k insns, ${wallTime.inMilliseconds}ms)';
}
