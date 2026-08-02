import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class _MenuLabels {
  static const copy = 'Copy';
  static const paste = 'Paste';
  static const selectAll = 'Select all';
}

enum _MenuAction { copy, paste, selectAll }

/// Right-click menu for the demo terminal.
///
/// Keyboard copy on the web can collide with browser shortcuts, so this
/// menu is the always-available path: it needs no keyboard at all and
/// works identically in every browser.
class TerminalContextMenu {
  /// Creates a menu acting on [terminal] and [controller].
  const TerminalContextMenu({
    required this.terminal,
    required this.controller,
    required this.focusNode,
  });

  /// Terminal the menu acts on.
  final Terminal terminal;

  /// Selection state for copy and select-all.
  final TerminalController controller;

  /// Refocused after the menu closes so typing resumes immediately.
  final FocusNode focusNode;

  /// Shows the menu at [position] and performs the chosen action.
  Future<void> show(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_MenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _MenuAction.copy,
          enabled: controller.selection != null,
          child: const Text(_MenuLabels.copy),
        ),
        const PopupMenuItem(
          value: _MenuAction.paste,
          child: Text(_MenuLabels.paste),
        ),
        const PopupMenuItem(
          value: _MenuAction.selectAll,
          child: Text(_MenuLabels.selectAll),
        ),
      ],
    );

    switch (action) {
      case _MenuAction.copy:
        await _copy();
      case _MenuAction.paste:
        await _paste();
      case _MenuAction.selectAll:
        _selectAll();
      case null:
        break;
    }
    focusNode.requestFocus();
  }

  Future<void> _copy() async {
    final selection = controller.selection;
    if (selection == null) return;
    await Clipboard.setData(
      ClipboardData(text: terminal.buffer.getText(selection)),
    );
    controller.clearSelection();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    terminal.paste(text);
    controller.clearSelection();
  }

  void _selectAll() {
    controller.setSelection(
      terminal.buffer.createAnchor(
        0,
        terminal.buffer.height - terminal.viewHeight,
      ),
      terminal.buffer.createAnchor(
        terminal.viewWidth,
        terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
  }
}
