const stepsPerEventLoopYield = 8;

Future<void> yieldToEventLoop() => Future<void>.delayed(Duration.zero);
