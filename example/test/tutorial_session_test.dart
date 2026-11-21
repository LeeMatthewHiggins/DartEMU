import 'package:dart_emu_example/src/tutorial/tutorial_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> input;
  late List<Map<String, String>> messages;
  late TutorialSession session;

  setUp(() {
    input = [];
    messages = [];
    session = TutorialSession(sendInput: input.add, postMessage: messages.add);
  });

  tearDown(() => session.dispose());

  test('waits for the shell prompt even when output splits it', () {
    session
      ..receiveMessage({'type': 'dartemu:run', 'id': 'inspect'})
      ..receiveOutput('Linux booting...\r\n/ #');
    expect(input, isEmpty);
    expect(messages, isEmpty);

    session.receiveOutput(' ');
    expect(messages, [
      {'type': 'dartemu:ready'},
    ]);
    expect(input, isEmpty, reason: 'early requests must not be queued');
  });

  test('runs only the known example and waits for its next prompt', () {
    session
      ..receiveOutput('/ # ')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'inspect'})
      ..receiveMessage({'type': 'dartemu:run', 'id': 'files'});
    expect(input, ['uname -m; cat /proc/cpuinfo\n']);
    expect(messages.last, {'type': 'dartemu:running', 'id': 'inspect'});

    session.receiveOutput('uname -m; cat /proc/cpuinfo\r\nriscv32\r\n');
    expect(messages.last['type'], 'dartemu:running');
    session.receiveOutput('/ # ');
    expect(messages.last, {'type': 'dartemu:complete', 'id': 'inspect'});

    session.receiveMessage({'type': 'dartemu:run', 'id': 'files'});
    expect(input, hasLength(2));
    expect(input.last, endsWith('cat /tmp/tutorial/weather.txt\n'));
  });

  test('ignores malformed messages, unknown IDs and arbitrary commands', () {
    session.receiveOutput('/ # ');
    for (final message in <Object?>[
      null,
      'inspect',
      ['dartemu:run', 'inspect'],
      <String, String>{},
      {'type': 'other', 'id': 'inspect'},
      {'type': 'dartemu:run', 'id': 'reboot'},
      {'type': 'dartemu:run', 'id': 1},
      {'type': 'dartemu:run', 'command': 'reboot'},
    ]) {
      session.receiveMessage(message);
    }
    expect(input, isEmpty);
    expect(messages, hasLength(1));

    session.receiveMessage({
      'type': 'dartemu:run',
      'id': 'inspect',
      'command': 'reboot',
    });
    expect(input, ['uname -m; cat /proc/cpuinfo\n']);
  });

  test('does not append an example to manually typed terminal input', () {
    session
      ..receiveOutput('/ # ')
      ..receiveUserInput('echo manual')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'files'})
      ..receiveOutput('echo manual');
    expect(input, isEmpty);
    expect(messages, hasLength(1));

    session
      ..receiveOutput('\r\nmanual\r\n/ # ')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'files'});
    expect(input, hasLength(1));
    expect(messages[1], {'type': 'dartemu:ready'});
  });

  test('pipeline input keeps escaped newlines in one shell command', () {
    session
      ..receiveOutput('/ # ')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'pipeline'});
    expect(input.single, contains(r"printf '%s\n'"));
    expect(input.single, contains('sort -r -k2 | head -n 2'));
    expect('\n'.allMatches(input.single), hasLength(1));
  });

  test('script input preserves guest shell variable expansion', () {
    session
      ..receiveOutput('/ # ')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'script'});
    expect(input.single, startsWith('limit=16; y=-8;'));
    expect(input.single, contains(r'row="$row$p"'));
    expect(input.single, endsWith('y=\$((y+1)); done\n'));
    expect('\n'.allMatches(input.single), hasLength(1));
  });

  test('chart hashes do not look like a completed shell prompt', () {
    session
      ..receiveOutput('/ # ')
      ..receiveMessage({'type': 'dartemu:run', 'id': 'chart'})
      ..receiveOutput('attic   ############################### ');
    expect(messages.last, {'type': 'dartemu:running', 'id': 'chart'});

    session.receiveOutput('31 C\r\n~ # ');
    expect(messages.last, {'type': 'dartemu:complete', 'id': 'chart'});
  });

  test('recognizes an ANSI-decorated prompt after long boot output', () {
    session.receiveOutput('${'boot message\r\n' * 100}\x1b[32m/ # \x1b[0m');
    expect(messages, [
      {'type': 'dartemu:ready'},
    ]);
  });

  test('failure and disposal remove the listener and disable dispatch', () {
    var disposals = 0;
    session =
        TutorialSession(
            sendInput: input.add,
            postMessage: messages.add,
            onDispose: () => disposals++,
          )
          ..receiveOutput('/ # ')
          ..fail('Boot failed')
          ..receiveMessage({'type': 'dartemu:run', 'id': 'inspect'})
          ..receiveOutput('/ # ')
          ..dispose();
    expect(input, isEmpty);
    expect(messages.last, {'type': 'dartemu:error', 'message': 'Boot failed'});
    expect(disposals, 1);
  });

  test('recognizes home and directory prompts after manual commands', () {
    for (final prompt in ['~ # ', '~/work # ', '/ # ', '/tmp/tutorial # ']) {
      session
        ..receiveUserInput('cd\n')
        ..receiveOutput(prompt);
    }
    expect(messages, hasLength(4));
    expect(
      messages.every((message) => message['type'] == 'dartemu:ready'),
      isTrue,
    );
  });

  test('native applications have no browser bridge', () {
    expect(createTutorialBridge(sendInput: input.add), isNull);
  });
}
