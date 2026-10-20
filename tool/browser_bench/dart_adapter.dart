import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_emu/dart_emu.dart';

@JS('adapter')
external set adapter(JSObject value);
@JS('ready')
// A JS property setter requires a positional parameter.
// ignore: avoid_positional_boolean_parameters
external set ready(bool value);
@JS('assetLoadMs')
external set assetLoadMs(double value);
@JS('fetch')
external JSPromise<Response> fetch(JSString url);

extension type Response(JSObject _) implements JSObject {
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type Adapter._(JSObject _) implements JSObject {
  external factory Adapter({
    JSFunction boot,
    JSFunction exec,
    JSFunction snapshot,
    JSFunction resume,
    JSFunction dispose,
    JSFunction readFile,
    JSFunction writeFile,
    JSFunction memory,
  });
}

extension type Result._(JSObject _) implements JSObject {
  external factory Result({
    String stdout,
    int? exitCode,
    String outcome,
    int instructions,
  });
}

extension type Memory._(JSObject _) implements JSObject {
  external factory Memory({int configuredGuestBytes, int snapshotBytes});
}

late SandboxConfig config;
AgentSandbox? sandbox;
MachineSnapshot? saved;
Future<Uint8List> load(String name) async {
  final response = await fetch('assets/dart/$name'.toJS).toDart;
  if (response.status != 200) {
    throw StateError('Asset $name HTTP ${response.status}');
  }
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

Future<JSAny?> boot() async {
  sandbox = AgentSandbox(config);
  await sandbox!.boot();
  return null;
}

Future<Result> exec(JSString command) async {
  final result = await sandbox!.exec(command.toDart);
  if (result.outcome != ExecOutcome.completed) {
    throw StateError('${result.outcome.name}: ${result.stdout}');
  }
  return Result(
    stdout: result.stdout,
    exitCode: result.exitCode,
    outcome: result.outcome.name,
    instructions: result.instructions,
  );
}

Future<JSNumber> snapshot() async {
  saved = sandbox!.snapshot();
  return saved!.sizeBytes.toJS;
}

Future<Result> resume() async {
  await sandbox?.dispose();
  sandbox = AgentSandbox.restore(config, saved!);
  return exec('echo RESUMED'.toJS);
}

Future<JSAny?> dispose() async {
  await sandbox?.dispose();
  sandbox = null;
  saved = null;
  return null;
}

Future<JSUint8Array> readFile(JSString path) async =>
    (await sandbox!.readFile(path.toDart)).toJS;
Future<Result> writeFile(JSString path, JSUint8Array data) async {
  final result = await sandbox!.writeFile(path.toDart, data.toDart);
  return Result(
    stdout: result.stdout,
    exitCode: result.exitCode,
    outcome: result.outcome.name,
    instructions: result.instructions,
  );
}

Future<void> main() async {
  final watch = Stopwatch()..start();
  final images = await Future.wait(
    ['bbl64.bin', 'kernel-riscv64.bin', 'root-riscv64.bin'].map(load),
  );
  config = SandboxConfig(
    biosData: images[0],
    kernelData: images[1],
    rootfsData: images[2],
    // Pin the benchmark memory size even if the library default changes.
    // ignore: avoid_redundant_argument_values
    memorySizeMb: 128,
    bootTimeout: const Duration(seconds: 120),
    defaultTimeout: const Duration(seconds: 120),
  );
  assetLoadMs = watch.elapsedMicroseconds / 1000;
  adapter = Adapter(
    boot: (() => boot().toJS).toJS,
    exec: ((JSString cmd) => exec(cmd).toJS).toJS,
    snapshot: (() => snapshot().toJS).toJS,
    resume: (() => resume().toJS).toJS,
    dispose: (() => dispose().toJS).toJS,
    readFile: ((JSString path) => readFile(path).toJS).toJS,
    writeFile: ((JSString path, JSUint8Array data) => writeFile(
      path,
      data,
    ).toJS).toJS,
    memory: (() => Memory(
      configuredGuestBytes: 128 * 1024 * 1024,
      snapshotBytes: saved?.sizeBytes ?? 0,
    )).toJS,
  );
  ready = true;
}
