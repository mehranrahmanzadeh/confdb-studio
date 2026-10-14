import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// A vertical divider between two panes that can be dragged to resize them.
/// Also works from the keyboard (←/→ when focused); double-click resets.
class ResizeHandle extends StatefulWidget {
  const ResizeHandle({super.key, required this.label, required this.onDrag, required this.onReset});

  /// What it resizes, for screen readers and the tooltip ("Resize views panel").
  final String label;

  /// Horizontal movement in logical pixels; positive is to the right.
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  /// Width of the grab area; the visible line is 1–2 px in its middle.
  static const width = 9.0;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _hover = false;
  bool _dragging = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? 64.0 : 16.0;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onDrag(-step);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onDrag(step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover || _dragging || _focused;
    return Semantics(
      label: widget.label,
      hint: 'Use the left and right arrow keys to resize',
      child: Focus(
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Tooltip(
          message: '${widget.label} · double-click to reset',
          waitDuration: const Duration(milliseconds: 800),
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Count movement from the press, so the divider tracks the pointer exactly.
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (_) => setState(() => _dragging = true),
              onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
              onHorizontalDragEnd: (_) => setState(() => _dragging = false),
              onHorizontalDragCancel: () => setState(() => _dragging = false),
              onDoubleTap: widget.onReset,
              child: SizedBox(
                width: ResizeHandle.width,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: active ? 3 : 1,
                    color: active ? c.secondary : c.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
