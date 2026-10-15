import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_icons.dart';

/// An outlined select with a floating label, opening a menu: the designs'
/// `<button aria-haspopup="listbox">` fields (View, Snap, Signing key…).
class OutlinedSelect<T> extends StatelessWidget {
  const OutlinedSelect({
    super.key,
    required this.label,
    required this.child,
    required this.items,
    required this.onSelected,
    this.helper,
    this.enabled = true,
    this.minHeight = 56,
  });

  final String label;
  final Widget child;

  /// Menu entries: value, row widget.
  final List<(T, Widget)> items;
  final ValueChanged<T> onSelected;
  final String? helper;
  final bool enabled;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 2),
      menuChildren: [
        for (final (value, row) in items)
          MenuItemButton(
            onPressed: () => onSelected(value),
            style: MenuItemButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 16)),
            child: row,
          ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: enabled ? () => controller.isOpen ? controller.close() : controller.open() : null,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            isFocused: controller.isOpen,
            decoration: InputDecoration(
              labelText: label,
              helperText: helper,
              enabled: enabled,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              contentPadding: EdgeInsets.fromLTRB(16, (minHeight - 24) / 2, 12, (minHeight - 24) / 2),
              suffixIcon: Icon(controller.isOpen ? AppIcons.collapse : AppIcons.expand, color: c.onSurface),
            ),
            child: DefaultTextStyle.merge(style: context.text.bodyLarge?.mono.copyWith(fontSize: 15), child: child),
          ),
        ),
      ),
    );
  }
}

/// Lets a table keep its minimum width and scroll sideways when narrower,
/// with a scrollbar that stays visible so the hidden columns are discoverable
/// without a trackpad.
class MinWidthScroll extends StatefulWidget {
  const MinWidthScroll({super.key, required this.minWidth, required this.child});
  final double minWidth;
  final Widget child;

  @override
  State<MinWidthScroll> createState() => _MinWidthScrollState();
}

class _MinWidthScrollState extends State<MinWidthScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= widget.minWidth) return widget.child;
      return Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        trackVisibility: true,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          // Room for the scrollbar under the last row.
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(width: widget.minWidth, child: widget.child),
        ),
      );
    },
  );
}
