import 'dart:async';

import 'package:dart_emu_example/src/terminal/terminal_context_menu.dart';
import 'package:dart_emu_example/src/terminal/terminal_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/xterm.dart';

/// The demo's terminal surface: an xterm view with browser-safe shortcuts,
/// a right-click menu, and single-click focus recovery.
///
/// Kept separate from the emulator plumbing so the input behaviour — which
/// keys reach the guest, which the UI consumes — can be tested as a widget.
class DemoTerminalView extends StatefulWidget {
  /// Creates the terminal surface.
  const DemoTerminalView({
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.textStyle,
    this.hardwareKeyboardOnly = false,
    this.autofocus = true,
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

  /// Whether to focus the terminal when it first appears.
  final bool autofocus;

  /// Whether to accept only physical-keyboard input.
  final bool hardwareKeyboardOnly;

  @override
  State<DemoTerminalView> createState() => DemoTerminalViewState();
}

/// Maintains the terminal viewport independently of keyboard focus.
class DemoTerminalViewState extends State<DemoTerminalView> {
  final _scrollController = ScrollController();
  var _followingOutput = true;
  var _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onOutput);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(DemoTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onOutput);
      widget.terminal.addListener(_onOutput);
      resumeFollowingOutput();
    }
  }

  /// Shows the current prompt and follows subsequent output. Used when a
  /// tutorial starts a command without a keyboard event in the terminal.
  void resumeFollowingOutput() {
    _followingOutput = true;
    _scheduleScroll();
  }

  void _onOutput() {
    if (_followingOutput) _scheduleScroll();
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter <= _bottomTolerance) {
      _followingOutput = true;
    }
  }

  bool _onUserScroll(ScrollUpdateNotification notification) {
    if (notification.dragDetails != null ||
        (_scrollController.hasClients &&
            _scrollController.position.userScrollDirection !=
                ScrollDirection.idle)) {
      _followingOutput = notification.metrics.extentAfter <= _bottomTolerance;
    }
    return false;
  }

  void _scheduleScroll() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_followingOutput || !_scrollController.hasClients) {
        return;
      }
      // Output changes the scroll extent during layout, so follow afterwards.
      final position = _scrollController.position;
      position.jumpTo(position.maxScrollExtent);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static const _bottomTolerance = 1.0;

  @override
  void dispose() {
    widget.terminal.removeListener(_onOutput);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contextMenu = TerminalContextMenu(
      terminal: widget.terminal,
      controller: widget.controller,
      focusNode: widget.focusNode,
    );

    // A tap that clears a selection skips xterm's own focus request,
    // leaving the keyboard dead until a second click. Its onTapUp callback
    // cannot patch this: xterm 4.0.0 accepts one but never invokes it. A
    // raw Listener sits outside the gesture arena, so every pointer-up —
    // tap, selection drag, anything — restores focus and one click is
    // always enough.
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: _onUserScroll,
      child: Listener(
        onPointerUp: (_) => widget.focusNode.requestFocus(),
        child: TerminalView(
          widget.terminal,
          controller: widget.controller,
          scrollController: _scrollController,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
          shortcuts: terminalShortcuts(),
          onSecondaryTapUp: (details, _) =>
              unawaited(contextMenu.show(context, details.globalPosition)),
          textStyle: widget.textStyle,
        ),
      ),
    );
  }
}
