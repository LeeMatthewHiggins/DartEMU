import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

class _Style {
  static const borderWidth = 2.0;
  static const borderRadius = 12.0;
  static const padding = 32.0;
  static const hoverOpacity = 0.08;
}

/// A drag-and-drop zone with visual feedback on hover.
class DropTargetArea extends StatefulWidget {
  /// Creates a drop target that wraps [child] and calls [onFileDropped]
  /// with the path of the first dropped file.
  const DropTargetArea({
    required this.child,
    required this.onFileDropped,
    super.key,
  });

  /// The content displayed inside the drop zone.
  final Widget child;

  /// Called with the file path when a file is dropped.
  final ValueChanged<String> onFileDropped;

  @override
  State<DropTargetArea> createState() => _DropTargetAreaState();
}

class _DropTargetAreaState extends State<DropTargetArea> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: _onDragDone,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(_Style.padding),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_Style.borderRadius),
          border: Border.all(
            color: _hovering ? Colors.blueAccent : Colors.grey.shade700,
            width: _Style.borderWidth,
          ),
          color: _hovering
              ? Colors.blueAccent.withValues(alpha: _Style.hoverOpacity)
              : Colors.transparent,
        ),
        child: widget.child,
      ),
    );
  }

  void _onDragDone(DropDoneDetails details) {
    setState(() => _hovering = false);
    if (details.files.isEmpty) return;
    widget.onFileDropped(details.files.first.path);
  }
}
