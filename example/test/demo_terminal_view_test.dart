import 'package:dart_emu_example/src/terminal/demo_terminal_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class _Bytes {
  /// What a real terminal sends for `Ctrl+A` (start-of-line in readline).
  static const ctrlA = '\x01';

  /// What a real terminal sends for `Ctrl+V` (literal-next in readline).
  static const ctrlV = '\x16';
}

class _Harness {
  _Harness()
    : terminal = Terminal(),
      controller = TerminalController(),
      focusNode = FocusNode() {
    terminal.onOutput = output.write;
  }

  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focusNode;
  final StringBuffer output = StringBuffer();

  Widget build() => MaterialApp(
    home: Scaffold(
      body: DemoTerminalView(
        terminal: terminal,
        controller: controller,
        focusNode: focusNode,
        hardwareKeyboardOnly: true,
        textStyle: const TerminalStyle(),
      ),
    ),
  );

  void selectFirstLine() {
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(5, 0),
    );
  }

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

Future<void> _pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> _pressCtrlShift(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The shortcut map differs by platform; these tests exercise the
  /// non-Apple one, which is what browsers on Windows and Linux get.
  final nonApple = TargetPlatformVariant.only(TargetPlatform.linux);

  group('guest control keys reach the shell', () {
    testWidgets('Ctrl+A is sent to the guest, not select-all', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(h.build());

      await _pressCtrl(tester, LogicalKeyboardKey.keyA);

      expect(h.output.toString(), _Bytes.ctrlA);
      expect(
        h.controller.selection,
        isNull,
        reason: 'select-all would have created a selection',
      );
      h.dispose();
    }, variant: nonApple);

    testWidgets('Ctrl+V is sent to the guest, not paste', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(h.build());

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);

      expect(h.output.toString(), _Bytes.ctrlV);
      h.dispose();
    }, variant: nonApple);
  });

  group('copy and paste stay available', () {
    testWidgets('Ctrl+Insert copies the selection to the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );

      final h = _Harness();
      h.terminal.write('hello');
      await tester.pumpWidget(h.build());
      h.selectFirstLine();

      await _pressCtrl(tester, LogicalKeyboardKey.insert);

      expect(copied, isNotNull);
      expect(copied, contains('hello'));
      expect(
        h.output.toString(),
        isEmpty,
        reason: 'a copy chord must not leak bytes into the guest',
      );
      h.dispose();
    }, variant: nonApple);

    testWidgets('Ctrl+Shift+C is a copy alias, not guest input', (
      tester,
    ) async {
      var copyRequested = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copyRequested = true;
          return null;
        },
      );

      final h = _Harness();
      h.terminal.write('hello');
      await tester.pumpWidget(h.build());
      h.selectFirstLine();

      await _pressCtrlShift(tester, LogicalKeyboardKey.keyC);

      expect(copyRequested, isTrue);
      expect(h.output.toString(), isEmpty);
      h.dispose();
    }, variant: nonApple);
  });

  group('one click resumes typing', () {
    testWidgets('a tap that clears a selection still restores focus', (
      tester,
    ) async {
      final h = _Harness();
      h.terminal.write('hello');
      await tester.pumpWidget(h.build());

      h.selectFirstLine();
      h.focusNode.unfocus();
      await tester.pump();
      expect(h.focusNode.hasFocus, isFalse);

      await tester.tap(find.byType(TerminalView));
      await tester.pump();

      expect(
        h.focusNode.hasFocus,
        isTrue,
        reason:
            'xterm clears the selection without refocusing; the view '
            'must request focus itself or typing needs a second click',
      );
      await tester.pump(kDoubleTapTimeout);
      h.dispose();
    }, variant: nonApple);
  });

  group('right-click menu', () {
    testWidgets('offers Copy, Paste and Select all', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(h.build());

      final center = tester.getCenter(find.byType(TerminalView));
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      h.dispose();
    }, variant: nonApple);
  });
}
