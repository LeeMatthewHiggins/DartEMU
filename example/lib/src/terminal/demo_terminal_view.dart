import 'dart:async';

import 'package:dart_emu_example/src/terminal/terminal_context_menu.dart';
import 'package:dart_emu_example/src/terminal/terminal_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// The demo's terminal surface: an xterm view with browser-safe shortcuts,
/// a right-click menu, and single-click focus recovery.
///
/// Kept separate from the emulator plumbing so the input behaviour — which
/// keys reach the guest, which the UI consumes — can be tested as a widget.
class DemoTerminalView extends StatelessWidget {
  /// Creates the terminal surface.
  const DemoTerminalView({
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.textStyle,
    this.hardwareKeyboardOnly = false,
    super.key,
  });

  /// Terminal backing the view.
  final Terminal terminal;

  /// Selection state, shared with the context menu.
  final TerminalController controller;

  /// Focus node owned by the caller so taps can always restore focus.
  final FocusNode focusNode;

  /// Text style for the terminal.
  final TerminalStyle textStyle;

  /// Whether to accept only physical-keyboard input.
  final bool hardwareKeyboardOnly;

  @override
  Widget build(BuildContext context) {
    final contextMenu = TerminalContextMenu(
      terminal: terminal,
      controller: controller,
      focusNode: focusNode,
    );

    // A tap that clears a selection skips xterm's own focus request,
    // leaving the keyboard dead until a second click. Its onTapUp callback
    // cannot patch this: xterm 4.0.0 accepts one but never invokes it. A
    // raw Listener sits outside the gesture arena, so every pointer-up —
    // tap, selection drag, anything — restores focus and one click is
    // always enough.
    return Listener(
      onPointerUp: (_) => focusNode.requestFocus(),
      child: TerminalView(
        terminal,
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        hardwareKeyboardOnly: hardwareKeyboardOnly,
        shortcuts: terminalShortcuts(),
        onSecondaryTapUp: (details, _) =>
            unawaited(contextMenu.show(context, details.globalPosition)),
        textStyle: textStyle,
      ),
    );
  }
}
