/// CPU-profiles the emulator while it runs benchmark workloads.
///
/// Uses the Dart VM's sampling profiler via the VM service, so results
/// attribute time to real Dart functions. Boots the machine, runs the
/// selected workloads, then reports functions ranked by exclusive
/// (self) sample count.
///
/// Must be launched with the VM service and profiler enabled:
///
///   dart --enable-vm-service=0 --disable-service-auth-codes \
///     tool/bench/profile.dart [--xlen rv64] [--workloads a,b] [--top 30]
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_emu/dart_emu.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'src/runner.dart';
import 'src/workloads.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'xlen',
      allowed: ['rv32', 'rv64'],
      defaultsTo: 'rv64',
      help: 'Guest architecture.',
    )
    ..addOption(
      'assets',
      defaultsTo: 'example/assets',
      help: 'Directory containing bios/kernel/rootfs images.',
    )
    ..addOption(
      'workloads',
      help: 'Comma-separated workload names (default: a CPU-heavy subset).',
    )
    ..addOption('top', defaultsTo: '30', help: 'Number of functions to report.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final options = parser.parse(args);
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final serviceInfo = await developer.Service.getInfo();
  final serviceUri = serviceInfo.serverUri;
  if (serviceUri == null) {
    stderr
      ..writeln('VM service not available. Launch with:')
      ..writeln(
        '  dart --enable-vm-service=0 --disable-service-auth-codes '
        'tool/bench/profile.dart',
      );
    exit(2);
  }

  final xlen = options['xlen'] == 'rv32' ? Xlen.rv32 : Xlen.rv64;
  final workloadNames =
      (options['workloads'] as String?)?.split(',') ?? _defaultWorkloads;
  final byName = {for (final w in Workloads.all) w.name: w};
  final workloads = [
    for (final name in workloadNames)
      byName[name.trim()] ?? (throw ArgumentError('unknown workload: $name')),
  ];

  stdout.writeln('booting and running: ${workloadNames.join(', ')}...');
  BenchRunner(
    xlen: xlen,
    assetsDir: options['assets'] as String,
    workloads: workloads,
  ).run();

  final wsUri = serviceUri.replace(scheme: 'ws', path: '${serviceUri.path}ws');
  final service = await vmServiceConnectUri(wsUri.toString());
  final vm = await service.getVM();
  final isolateId = vm.isolates!.first.id!;

  final samples = await service.getCpuSamples(
    isolateId,
    0,
    _maxTimeExtentMicros,
  );
  _report(samples, int.parse(options['top'] as String));
  await service.dispose();
}

const _defaultWorkloads = ['sh_loop_10k', 'awk_fp_50k', 'gzip_512k'];
const _maxTimeExtentMicros = 1 << 60;

void _report(CpuSamples samples, int top) {
  final functions = samples.functions ?? [];
  final sampleList = samples.samples ?? [];

  final selfCounts = <int, int>{};
  final totalCounts = <int, int>{};
  for (final sample in sampleList) {
    final stack = sample.stack;
    if (stack == null || stack.isEmpty) continue;
    selfCounts.update(stack.first, (count) => count + 1, ifAbsent: () => 1);
    for (final functionIndex in stack.toSet()) {
      totalCounts.update(
        functionIndex,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  final totalSamples = sampleList.length;
  final ranked = selfCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  stdout
    ..writeln()
    ..writeln(
      '$totalSamples samples @ ${samples.samplePeriod}us '
      '(${samples.sampleCount} recorded)',
    )
    ..writeln()
    ..writeln(
      '${'self%'.padLeft(_selfWidth)}${'total%'.padLeft(_totalWidth)}'
      '  function',
    );

  for (final entry in ranked.take(top)) {
    final name = _functionName(functions, entry.key);
    final selfPercent = entry.value / totalSamples * _percent;
    final totalPercent =
        (totalCounts[entry.key] ?? 0) / totalSamples * _percent;
    stdout.writeln(
      '${selfPercent.toStringAsFixed(1).padLeft(_selfWidth)}'
      '${totalPercent.toStringAsFixed(1).padLeft(_totalWidth)}'
      '  $name',
    );
  }
}

String _functionName(List<ProfileFunction> functions, int index) {
  if (index < 0 || index >= functions.length) return '<unknown>';
  final function = functions[index].function;
  if (function is FuncRef) {
    final owner = function.owner;
    final ownerName = owner is ClassRef ? '${owner.name}.' : '';
    return '$ownerName${function.name}';
  }
  if (function is NativeFunction) {
    return '[native] ${function.name}';
  }
  return functions[index].resolvedUrl ?? '<unresolved>';
}

const _selfWidth = 7;
const _totalWidth = 8;
const _percent = 100;
