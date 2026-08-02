import 'package:dart_emu/dart_emu.dart';
import 'package:dart_emu_example/src/agentos/agentos_demo.dart';
import 'package:dart_emu_example/src/agentos/api_key_dialog.dart';
import 'package:dart_emu_example/src/config/config_picker_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentOsDemo', () {
    test('reaches exactly one destination', () {
      final upstreams = AgentOsDemo.upstreams();
      expect(upstreams, hasLength(1));
      expect(upstreams.single.host, AgentOsDemo.upstreamHost);
      expect(upstreams.single.target, AgentOsDemo.upstreamTarget);
    });

    test('carries a placeholder where a key would go', () {
      final header = AgentOsDemo.upstreams().single.injectHeaders.values.single;
      expect(header, contains('\${${AgentOsDemo.credentialName}}'));
      expect(header, isNot(contains('sk-')));
    });

    test('the upstream keeps its own path prefix', () {
      // The guest asks for /v1/chat/completions; sending that to the site
      // root instead of the API is a mistake this configuration must not
      // make, so the target is expected to carry the prefix itself.
      expect(AgentOsDemo.upstreamTarget.path, isNotEmpty);
      expect(AgentOsDemo.upstreamTarget.scheme, 'https');
    });
  });

  group('ApiKeyDialog', () {
    testWidgets('an empty field boots without a key', (tester) async {
      final choice = await _showAndSubmit(tester, key: '');
      expect(choice, isNotNull);
      expect(choice!.hasKey, isFalse);
      expect(choice.key, isNull);
    });

    testWidgets('a pasted key is returned to the page', (tester) async {
      final choice = await _showAndSubmit(tester, key: '  sk-or-v1-abc  ');
      expect(choice!.hasKey, isTrue);
      expect(choice.key, 'sk-or-v1-abc');
    });

    testWidgets('cancelling boots nothing', (tester) async {
      final choice = await _showAndSubmit(
        tester,
        key: 'sk-or-v1-abc',
        cancel: true,
      );
      expect(choice, isNull);
    });
  });

  group('the picker', () {
    // The dialog needs a context below the app's Navigator. Raising it from
    // above one throws, and only running the real app shows that, so the
    // card is tapped here exactly as a visitor would tap it.
    testWidgets('the AgentOS card asks for a key and reports the choice', (
      tester,
    ) async {
      ApiKeyChoice? reported;
      await tester.pumpWidget(
        MaterialApp(
          home: ConfigPickerScreen(
            agentOsSupported: true,
            onConfigLoaded: (_) {},
            onDemoSelected: (_) {},
            onDemoWithShare: (_, __, ___) {},
            onAgentOsSelected: (choice) => reported = choice,
          ),
        ),
      );

      await tester.tap(find.text('AgentOS'));
      await tester.pumpAndSettle();
      expect(find.text('Boot AgentOS'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'sk-or-v1-abc');
      await tester.tap(find.widgetWithText(FilledButton, 'Boot'));
      await tester.pumpAndSettle();

      expect(reported?.key, 'sk-or-v1-abc');
    });

    testWidgets('the card is absent where the demo cannot run', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConfigPickerScreen(
            agentOsSupported: false,
            onConfigLoaded: (_) {},
            onDemoSelected: (_) {},
            onDemoWithShare: (_, __, ___) {},
            onAgentOsSelected: (_) {},
          ),
        ),
      );

      expect(find.text('AgentOS'), findsNothing);
    });
  });

  group('CredentialStore', () {
    test(
      'an empty key is the same as none, so the guest is refused by name',
      () {
        final store = CredentialStore()..set(AgentOsDemo.credentialName, null);
        expect(store.has(AgentOsDemo.credentialName), isFalse);

        store.set(AgentOsDemo.credentialName, 'sk-or-v1-abc');
        expect(store[AgentOsDemo.credentialName], 'sk-or-v1-abc');
      },
    );
  });
}

Future<ApiKeyChoice?> _showAndSubmit(
  WidgetTester tester, {
  required String key,
  bool cancel = false,
}) async {
  ApiKeyChoice? choice;
  var returned = false;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            choice = await ApiKeyDialog.show(context);
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  if (key.isNotEmpty) {
    await tester.enterText(find.byType(TextField), key);
  }
  await tester.tap(find.text(cancel ? 'Cancel' : 'Boot'));
  await tester.pumpAndSettle();

  expect(returned, isTrue, reason: 'the dialog should have closed');
  return choice;
}
