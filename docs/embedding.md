# Embedding

Embed a machine in Flutter, web, CLI or server applications.

- [The lifecycle](#the-lifecycle)
- [Driving emulation](#driving-emulation)
- [Flutter](#flutter)
- [The web target](#the-web-target)
- [Choosing an architecture](#choosing-an-architecture)
- [Loading images](#loading-images)

## The lifecycle

`Emulator` is a machine plus two streams:

```dart
final emulator = Emulator(config);

emulator.output.listen((bytes) {
  terminal.write(utf8.decode(bytes, allowMalformed: true));
});
emulator.status.listen((status) => setState(() => _status = status));

// Forward terminal input while the emulator runs.
terminal.onOutput = (text) => emulator.sendInput(utf8.encode(text));

try {
  await emulator.start(); // completes on stop, guest shutdown, or an error
} finally {
  await emulator.dispose();
}
```

Here `terminal` is an xterm `Terminal`; import `dart:convert` for UTF-8.
Wait for the guest shell prompt before entering commands.

`EmulatorStatus` moves `idle → starting → running → stopped`, or to `error`
with the cause in `lastError`. Handle guest shutdown and reboot by showing a stopped state or restart
control.

## Driving emulation

Choose loop mode or frame mode.

**`start()`** runs the machine to completion, yielding to the event loop
periodically. Right for a CLI or a server-side task.

**`stepFor(micros)`** runs for a slice and returns. Right for anything with
a UI, because you decide when the machine gets time:

```dart
await emulator.init();
if (emulator.currentStatus != EmulatorStatus.running) {
  throw StateError('Emulator failed to initialize: ${emulator.lastError}');
}
_ticker = createTicker((_) => emulator.stepFor(12000))..start();
```

A frame budget below the frame interval leaves room to paint. The example
uses 12 ms against a 16 ms frame.

Browsers can impose a minimum delay on repeated
`setTimeout`/`Future.delayed` calls, reducing execution speed. A `Ticker`
runs with the display frame schedule.

## Flutter

The [example app](../example) is a complete implementation — config picker,
terminal, CRT shader, folder mounting — but the core is small:

```dart
class _TerminalState extends State<TerminalScreen>
    with TickerProviderStateMixin {
  late final Emulator _emulator;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _emulator = Emulator(widget.config);
    _emulator.output.listen((b) => _terminal.write(utf8.decode(b,
        allowMalformed: true)));
    _terminal.onOutput = (text) => _emulator.sendInput(utf8.encode(text));
    unawaited(_start());
  }

  Future<void> _start() async {
    await _emulator.init();
    if (!mounted || _emulator.currentStatus != EmulatorStatus.running) return;
    _ticker = createTicker((_) => _emulator.stepFor(12000))..start();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    unawaited(_emulator.dispose());
    super.dispose();
  }
}
```

This sketch assumes a `TerminalScreen.config` and an xterm `_terminal`,
plus imports for `dart:async`, `dart:convert` and Flutter. Render
`_emulator.lastError` when initialization fails, and cancel subscriptions
when your UI owns them beyond the emulator lifetime.

The terminal also needs font and keyboard configuration:

**Bundle a monospace font.** Declare it in `pubspec.yaml`. A system font
name such as Menlo can fall back to a proportional font and cause incorrect
spacing in terminal cells.

**Terminal keys belong to the guest.** Ctrl+A, Ctrl+V and friends must reach
the shell rather than being intercepted as select-all and paste. Keep an
explicit copy/paste path (Ctrl+Insert, Ctrl+Shift+C) instead.

## The web target

```sh
cd example
flutter build web --wasm --release
```

`--wasm` compiles to WebAssembly (WasmGC) and ships the JavaScript build as
an automatic fallback for browsers without it. A browser downloads one, not
both.

**Without `--wasm` there is no 64-bit register file, so every RV64 guest
disappears.** If your app offers RV64 at all, gate it:

```dart
const isWasm = bool.fromEnvironment('dart.tool.dart2wasm');
const isRv64Supported = !kIsWeb || isWasm;
```

Show the picker with an explanation when the requested architecture is
unsupported.

The hosted tutorial is the landing page. Use `terminal.html?boot=32` or
`terminal.html?boot=64` to open a bundled guest directly, and `terminal.html`
for the picker. GitHub Pages uses the JavaScript build and supports RV32;
the [Firebase build](https://dartemu-3ef91.web.app/?boot=64) also supports
RV64 when the browser runs WasmGC. The Flutter app accepts `?bundle=<url>`
to preload a custom ZIP. See the [browser tutorial](browser-tutorial.md) and
[deployment guide](../example/README.md).

On the JavaScript backend, the bundled RV32 guest produced no rows for an
`awk` filter using `$2 >= 20` and no bars for a numeric `awk` chart loop;
the same commands worked on native Dart. The tutorial uses text sorting
and integer shell loops.

## Choosing an architecture

| | RV32 | RV64 |
| --- | --- | --- |
| JavaScript web backend | yes | **no** |
| WasmGC web backend | yes | yes |
| Native | yes | yes |
| Recorded native benchmarks | faster on tested workloads | slower on tested workloads |
| Bundled demo image | 4 MB | 24 MB, ships a C compiler |

Prefer **RV32** unless you need a 64-bit address space or the toolchain in
the RV64 image. RV32 also supports the JavaScript browser fallback; measure
your own workload when speed matters.

## Loading images

Load images as bytes, a native YAML configuration, or a bundle:

**Bytes you already have** — construct `MachineConfig` with `biosData`,
`kernelData` and `blockDevices: [MemoryBlockDevice.fromData(rootfsBytes)]`.
Works everywhere.

**A YAML file** — `ConfigLoader.loadFromFile(path)` then
`ConfigResolver.resolve(config)`. Needs `dart:io`.

**A `.zip` bundle** — one archive with the config and everything it names.
The example app's import format for custom machines, and convenient for
sharing a complete configuration. See [Bundles](configuration.md#bundles).
