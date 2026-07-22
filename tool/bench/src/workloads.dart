/// A guest shell command with a completion marker computed at runtime
/// by the guest, so the tty echo of the typed command line never
/// contains the literal marker text.
class Workload {
  const Workload(this.name, this.body, {this.description = ''});

  /// Phase name used in reports and baseline comparisons.
  final String name;

  /// The shell command to execute, without marker plumbing.
  final String body;

  /// What emulator subsystem this workload stresses.
  final String description;

  /// Full command line: runs [body], then echoes its exit status
  /// followed by the computed completion marker.
  String command(int sequence) =>
      '$body; echo \$?:B\$((${_markerBase - _markerOffset}+'
      '${sequence + _markerOffset}))E';

  /// The marker text the guest computes for this [sequence].
  String marker(int sequence) => 'B${_markerBase + sequence}E';

  static const _markerBase = 663000;
  static const _markerOffset = 7;
}

/// The benchmark workload suite.
///
/// Each workload targets a distinct emulator subsystem so that a
/// regression or win in one area is visible in isolation. All commands
/// are busybox-compatible and run on the minimal rootfs.
class Workloads {
  /// Workloads included in `--quick` runs.
  static const quick = ['sh_loop_10k', 'pipe_64k', 'disk_read_4m', 'fork_100'];

  /// The full suite, in execution order.
  static const all = [
    Workload(
      'exec_true',
      'true',
      description: 'Single-command round-trip latency (agent exec latency)',
    ),
    Workload(
      'fork_100',
      r'i=0; while [ $i -lt 100 ]; do /bin/true; i=$((i+1)); done',
      description: 'Process creation: fork+exec of 100 binaries',
    ),
    Workload(
      'sh_loop_10k',
      r'i=0; while [ $i -lt 10000 ]; do i=$((i+1)); done',
      description: 'Shell interpreter arithmetic (integer ALU, branches)',
    ),
    Workload(
      'pipe_64k',
      'yes | head -n 65536 | wc -l',
      description: 'Pipes and context switches between processes',
    ),
    Workload(
      'awk_fp_50k',
      "awk 'BEGIN { x=0; for (i=0; i<50000; i++) x += i*0.5; print x }'",
      description: 'Soft-float FP arithmetic via awk',
    ),
    Workload(
      'sort_8k',
      "awk 'BEGIN { for (i=0; i<8000; i++) print (i*7919)%9973 }'"
          ' | sort -n | tail -n 1',
      description: 'Text generation, sorting, memory allocation',
    ),
    Workload(
      'gzip_512k',
      'dd if=/dev/vda bs=65536 count=8 2>/dev/null | gzip -c | wc -c',
      description: 'Integer compression over real disk data',
    ),
    Workload(
      'sha256_1m',
      'dd if=/dev/vda bs=65536 count=16 2>/dev/null | sha256sum',
      description: 'Integer hashing (ALU + shifts + memory)',
    ),
    Workload(
      'dd_64m',
      'dd if=/dev/zero of=/dev/null bs=65536 count=1024',
      description: 'Kernel memcpy and syscall path, no device I/O',
    ),
    Workload(
      'disk_read_4m',
      'dd if=/dev/vda of=/dev/null bs=65536',
      description: 'VirtIO block device sequential read',
    ),
    Workload(
      'disk_write_1m',
      'dd if=/dev/zero of=/root/bench.tmp bs=4096 count=256 2>/dev/null'
          ' && sync && rm -f /root/bench.tmp && sync',
      description: 'VirtIO block device write through ext2 + sync',
    ),
  ];
}
