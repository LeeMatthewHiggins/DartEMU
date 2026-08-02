import 'package:dart_emu_example/src/agentos/agentos_demo.dart';
import 'package:flutter/material.dart';

class _DialogLayout {
  static const spacing = 16.0;
  static const smallSpacing = 8.0;
  static const maxWidth = 420.0;
  static const noteFontSize = 12.0;
}

/// What the visitor chose to do about a key.
class ApiKeyChoice {
  const ApiKeyChoice._(this.key);

  /// Boot with this key held on the page.
  const ApiKeyChoice.withKey(String key) : this._(key);

  /// Boot without one, so the machine's requests are refused by name.
  const ApiKeyChoice.keyless() : this._(null);

  /// The key, or null when the visitor chose to go without.
  final String? key;

  /// Whether a key was supplied.
  bool get hasKey => key != null;
}

/// Asks for a key before booting, and explains where it will and will not go.
///
/// Booting without one is a first-class choice: the machine then reaches the
/// point of asking and is refused by name, which is the clearest way to see
/// that it never held the credential in the first place.
class ApiKeyDialog extends StatefulWidget {
  /// Creates the dialog.
  const ApiKeyDialog({super.key});

  /// Shows the dialog, returning null when dismissed.
  static Future<ApiKeyChoice?> show(BuildContext context) {
    return showDialog<ApiKeyChoice>(
      context: context,
      builder: (context) => const ApiKeyDialog(),
    );
  }

  @override
  State<ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<ApiKeyDialog> {
  final _controller = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _boot() {
    final key = _controller.text.trim();
    Navigator.of(context).pop(
      key.isEmpty ? const ApiKeyChoice.keyless() : ApiKeyChoice.withKey(key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtle = TextStyle(
      color: Colors.grey.shade500,
      fontSize: _DialogLayout.noteFontSize,
    );

    return AlertDialog(
      backgroundColor: Colors.grey.shade900,
      title: const Text('Boot AgentOS'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _DialogLayout.maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The machine talks to a model through this page. Paste an '
              'OpenRouter key to give it something to talk to.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: _DialogLayout.spacing),
            TextField(
              controller: _controller,
              obscureText: _obscured,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'OpenRouter key (optional)',
                hintText: 'sk-or-...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscured ? Icons.visibility : Icons.visibility_off,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              onSubmitted: (_) => _boot(),
            ),
            const SizedBox(height: _DialogLayout.spacing),
            Text(
              'The key stays in this browser tab. It is attached to requests '
              'on their way out and is never written into the machine, which '
              'only ever sees the name '
              '\${${AgentOsDemo.credentialName}}.',
              style: subtle,
            ),
            const SizedBox(height: _DialogLayout.smallSpacing),
            Text(
              'Leave it empty to boot anyway. The machine will run, ask, and '
              'be told which credential it is missing.',
              style: subtle,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _boot, child: const Text('Boot')),
      ],
    );
  }
}
