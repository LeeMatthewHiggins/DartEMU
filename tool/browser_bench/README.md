# Browser sandbox benchmarks

These are the DartEMU workloads from the October 2026 browser comparison.
The guest commands, timing boundaries, warmup policy, and correctness checks
are unchanged. Paths and result destinations are configurable for reuse.

Run from the repository root. Use the same Dart SDK, browser, guest images,
and machine for both revisions. The recorded study uses Dart 3.13.5,
Playwright 1.56.1, Chromium 155.0.8059.79, and `dart compile wasm -O4`.

```sh
dart pub get --no-example
npm ci --prefix tool/browser_bench --ignore-scripts --no-audit --no-fund
mkdir -p tool/browser_bench/assets/dart
cp example/assets/bbl64.bin example/assets/kernel-riscv64.bin \
  example/assets/root-riscv64.bin tool/browser_bench/assets/dart/
dart compile wasm -O4 --packages=.dart_tool/package_config.json \
  tool/browser_bench/dart_adapter.dart -o tool/browser_bench/dart_adapter.wasm
{ uname -srm; lscpu; dart --version; chromium --version; node --version; } \
  > tool/browser_bench/environment.txt
sha256sum tool/browser_bench/assets/dart/*
python3 -m http.server 18765 --bind 127.0.0.1 --directory tool/browser_bench
```

In another terminal, run these commands in order. Do not run other tests or
benchmarks at the same time.

```sh
BENCH_RESULTS="$PWD/before" node tool/browser_bench/run.cjs
BENCH_RESULTS="$PWD/before" node tool/browser_bench/responsiveness.cjs
```

Rebuild the other revision with the same commands. Use a different result
directory. `BENCH_ORIGIN` can select a different local server. The default
browser path is `/usr/bin/chromium`. Record any change to it. Chromium needs
a short private `TMPDIR` path for Unix sockets; long workspace paths fail
before a test starts.

One warmup is excluded. Each test retains five measured samples. Report the
median and range for every workload, including regressions and failures.
Repeat the comparison if host load makes the result unclear. Source pins,
compiled module hashes, environment details, and all samples belong with
the report. Use elapsed-time reduction and speedup as separate values.

The CPU test must return `35000`. File tests check a 1 MiB write, its SHA-256,
100 file records, and all 100 histogram rows. Export checks the downloaded
bytes against the guest output. Snapshot resume restores the in-memory VM.
The persistence test checks exported file bytes in IndexedDB after reload;
it does not test durable VM disk persistence.

The responsiveness test uses a 16 ms browser timer during the original
10,000-iteration AWK command. It records each timer delay and the result.
It measures event-loop progress, not frame rate. Browser scheduling and host
load can affect it. Retain the full delay arrays.
