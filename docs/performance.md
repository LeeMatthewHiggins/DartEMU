# Performance

What it costs to run a machine, how to measure it, and where the time goes.

- [Guest throughput](#guest-throughput)
- [Boot, and the cheaper alternative](#boot-and-the-cheaper-alternative)
- [Where the speed comes from](#where-the-speed-comes-from)
- [Web download size](#web-download-size)
- [Benchmarking](#benchmarking)
- [Measuring a change](#measuring-a-change)

## Guest throughput

Measured with the bundled suite (`tool/bench/bench.dart`, best of 3) on an
Apple M3 Pro, Dart 3.12.2. **These numbers are host-specific — re-run the
suite on your own hardware rather than trusting the table.**

| Workload | RV64 | RV32 |
| --- | --- | --- |
| boot to shell | **0.57 s** | **0.54 s** |
| sha256 of 1 MB | 109 MIPS | 158 MIPS |
| gzip 512 KB | 108 MIPS | 131 MIPS |
| soft-float (awk) | 93 MIPS | 106 MIPS |
| pipes + context switches | 91 MIPS | 113 MIPS |
| process creation (100 forks) | 81 MIPS | 83 MIPS |
| shell arithmetic loop | 77 MIPS | 107 MIPS |

RV32 is consistently faster: 32-bit arithmetic avoids the 64-bit paths the
Dart VM handles less cheaply. If your guest does not need a 64-bit address
space, RV32 is the faster choice on every backend — and the only one that
runs on the JavaScript web backend at all.

## Boot, and the cheaper alternative

Half a second to a shell is fast enough that booting per task is reasonable.
Restoring a snapshot is faster still — **29 ms against a 1.1 s cold boot
(~37x)** in `test/sandbox/snapshot_restore_test.dart`.

If you are running many short tasks, boot once, snapshot, and restore per
task. See [Snapshot and restore](agents.md#snapshot-and-restore).

## Where the speed comes from

Roughly in order of contribution:

- **A predecoded instruction cache** in front of the decoder — about 1.7x on
  RV64 and 1.9x on RV32. Decoding is the dominant cost in a naive
  interpreter, and most instructions are executed many times.
- **A separate RV32 predecoder**, so the 32-bit path never touches 64-bit
  arithmetic.
- **Inline fast paths for memory access**, with the TLB checked before the
  general page-walk machinery.
- **Block-boundary checks** rather than per-instruction bookkeeping for
  timers and interrupts.
- **WasmGC over JavaScript** on the web — roughly 1.4–1.7x on guest
  workloads and kernel boot.

## Web download size

Served with brotli from Firebase Hosting:

| Artifact | Raw | Over the wire |
| --- | --- | --- |
| Engine — WasmGC (`main.dart.wasm` + loader) | 2.3 MB | **639 KB** |
| Engine — JavaScript fallback (`main.dart.js`) | 2.7 MB | **599 KB** |
| RV64 guest image (Linux + TCC) | 24 MB | 3.8 MB |
| RV64 kernel | 3.8 MB | 1.7 MB |
| RV32 guest image | 4 MB | 1.4 MB |

A browser downloads one engine, never both — the `--wasm` build ships the
JavaScript build as an automatic fallback. Uncompressed the wasm is the
smaller of the two, but JavaScript compresses better, so over the wire they
land within ~40 KB of each other; wasm buys roughly 1.5x faster execution
for that.

**The guest images dominate the payload.** The RV64 rootfs alone is about
six times the engine over the wire. If download size matters, that is the
only number worth attacking — shrink the image before optimising anything in
the emulator.

## Benchmarking

The suite measures wall time, retired instructions and MIPS for boot plus
workloads that each stress a distinct subsystem: exec round-trip latency,
process creation, shell CPU, pipes and context switches, soft-float,
sorting, compression, hashing, kernel memcpy and VirtIO block I/O. It boots
from an in-memory copy of the rootfs, so the asset images are never
modified.

```sh
dart tool/bench/bench.dart                    # RV32, 3 runs, full suite
dart tool/bench/bench.dart --xlen rv64        # RV64
dart tool/bench/bench.dart --quick            # 1 run, reduced set
dart tool/bench/bench.dart --list             # available workloads
dart tool/bench/bench.dart --workloads sh_loop_10k,disk_read_4m
```

Results are aggregated as best/median/mean with a coefficient-of-variation
column; `best` is the least noisy. Each workload's guest exit status is
checked, so a failing command is reported rather than silently timed — a
benchmark that measures a command which did not run is worse than no
benchmark.

## Measuring a change

Record a baseline, make the change, compare:

```sh
dart tool/bench/bench.dart --json > tool/bench/baselines/before.json
# ... make changes ...
dart tool/bench/bench.dart --json > tool/bench/baselines/after.json
dart tool/bench/compare.dart tool/bench/baselines/{before,after}.json
```

The compare tool marks a phase FASTER or SLOWER only when the delta exceeds
the measured noise of *both* baselines, which is what stops a run-to-run
wobble being read as a result. `--fail-on-regress <pct>` makes it usable as
a CI gate.

Baselines are host-specific and gitignored. Comparing one machine's numbers
against another's measures the machines.
