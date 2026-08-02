import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keyboard shortcuts for the demo terminal.
///
/// The xterm defaults bind `Ctrl+A`, `Ctrl+V` and `Ctrl+Shift+C` on
/// non-Apple platforms. The first two are readline keys the guest shell
/// needs — start-of-line and literal-next — so binding them in the UI makes
/// the shell feel broken, and `Ctrl+Shift+C` opens DevTools in Chromium
/// browsers, which makes copying unreliable.
///
/// Copy and paste therefore live on the classic terminal bindings
/// `Ctrl+Insert` and `Shift+Insert`, which no browser claims, with
/// `Ctrl+Shift+C` and `Ctrl+Shift+V` kept as best-effort aliases for
/// keyboards without an Insert key. There is no select-all binding:
/// `Ctrl+A` belongs to the guest and `Ctrl+Shift+A` is Chrome's tab
/// search. Select all is available from the right-click menu instead.
///
/// Apple platforms keep the stock meta-based bindings, which never
/// collide with guest control keys.
Map<ShortcutActivator, Intent> terminalShortcuts() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _appleShortcuts;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return _shortcuts;
  }
}

final Map<ShortcutActivator, Intent> _shortcuts = {
  const SingleActivator(LogicalKeyboardKey.insert, control: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.insert, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
};

final Map<ShortcutActivator, Intent> _appleShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
};
