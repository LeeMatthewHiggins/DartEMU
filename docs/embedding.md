# Embedding

Putting a machine inside an application — Flutter, web, CLI or server.

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

emulator.output.listen((bytes) => terminal.write(bytes));
emulator.status.listen((status) => setState(() => _status = status));

emulator.sendInput(utf8.encode('uname -a\n'));

await emulator.start();     // completes when the guest shuts down
await emulator.dispose();
```

`EmulatorStatus` moves `idle → starting → running → stopped`, or to `error`
with the cause in `lastError`. A guest that halts or reboots ends the run,
which is worth handling — a demo that goes blank on `poweroff` looks broken.

## Driving emulation

Two options, and the choice matters more than it first appears.

**`start()`** runs the machine to completion, yielding to the event loop
periodically. Right for a CLI or a server-side task.

**`stepFor(micros)`** runs for a slice and returns. Right for anything with
a UI, because you decide when the machine gets time:

```dart
_ticker = createTicker((_) => emulator.stepFor(12000));
await _ticker.start();
```

A frame budget below the frame interval leaves room to paint. The example
uses 12 ms against a 16 ms frame.

This is not a stylistic preference on the web: browsers clamp
`setTimeout`/`Future.delayed` to a few milliseconds minimum, so a machine
driven by delays runs at a fraction of its speed. A `Ticker` is paced by the
compositor instead.

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
    unawaited(_start());
  }

  Future<void> _start() async {
    await _emulator.init();
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

Two things the example learned the hard way and worth copying:

**Bundle a monospace font.** The web build resolves only fonts declared in
`pubspec.yaml`, so naming a system font like Menlo silently falls back to a
proportional face — and a terminal lays out fixed cells, so every glyph gets
padded to a width it does not fill. It looks broken and the cause is not
obvious.

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

Landing a visitor on a picker with an explanation is kinder than booting a
machine that crashes on its register file.

Add `?boot=32` or `?boot=64` to skip the picker and boot the bundled demo
directly.

## Choosing an architecture

| | RV32 | RV64 |
| --- | --- | --- |
| JavaScript web backend | yes | **no** |
| WasmGC web backend | yes | yes |
| Native | yes | yes |
| Speed | faster | slower |
| Bundled demo image | 4 MB | 24 MB, ships a C compiler |

Prefer **RV32** unless you need a 64-bit address space or the toolchain in
the RV64 image. It is faster on every backend and it is the only one that
runs everywhere.

## Loading images

Three ways, in increasing order of convenience for an end user:

**Bytes you already have** — `MachineConfig(biosData:, kernelData:,
blockDevices: [MemoryBlockDevice.fromData(bytes)])`. Works everywhere.

**A YAML file** — `ConfigLoader.loadFromFile(path)` then
`ConfigResolver.resolve(config)`. Needs `dart:io`.

**A `.zip` bundle** — one archive with the config and everything it names.
The only option in a browser, and the one to hand someone who just wants to
run a machine. See [Bundles](configuration.md#bundles).
