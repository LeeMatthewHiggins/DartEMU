// This directory is the existing CI target for browser runtime tests.
import 'dart:async';

import 'package:dart_emu/src/sandbox/yield_to_event_loop.dart';
import 'package:test/test.dart';

void main() {
  test('yields past pending microtasks to a new event task', () async {
    var completed = false;
    final yielded = yieldToEventLoop().then((_) => completed = true);

    expect(completed, isFalse);
    await Future<void>.value();
    expect(completed, isFalse);
    await yielded;
    expect(completed, isTrue);
  });

  test('completes concurrent requests once and in order', () async {
    final completed = <int>[];
    final requests = List.generate(
      32,
      (index) => yieldToEventLoop().then((_) => completed.add(index)),
    );

    await Future.wait(requests);
    expect(completed, List.generate(32, (index) => index));
    await yieldToEventLoop();
    expect(completed, hasLength(32));
  });

  test('supports independent concurrent yield loops', () async {
    Future<int> run(int count) async {
      var completed = 0;
      while (completed < count) {
        await yieldToEventLoop();
        completed++;
      }
      return completed;
    }

    expect(await Future.wait([run(7), run(19), run(31)]), [7, 19, 31]);
  });

  test('allows a timer to run while repeatedly yielding', () async {
    var timerFired = false;
    final timer = Timer(Duration.zero, () => timerFired = true);
    addTearDown(timer.cancel);

    // Bound the loop so a mistaken microtask-only implementation fails
    // instead of starving the test framework's own timeout timer forever.
    for (var i = 0; i < 100000 && !timerFired; i++) {
      await yieldToEventLoop();
    }

    expect(timerFired, isTrue);
  });
}
