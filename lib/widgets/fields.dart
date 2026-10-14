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

/// Lets a table keep its minimum width and scroll sideways when narrower.
class MinWidthScroll extends StatelessWidget {
  const MinWidthScroll({super.key, required this.minWidth, required this.child});
  final double minWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= minWidth) return child;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: minWidth, child: child),
      );
    },
  );
}

/// Activity filter chip: outlined, radius 8, opens a menu of options.
class FilterMenuChip extends StatelessWidget {
  const FilterMenuChip({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.monoOptions = false,
  });

  final String label;
  final List<String> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool monoOptions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selected = value != null;
    final optionStyle = monoOptions ? context.text.bodyMedium?.mono : context.text.bodyMedium;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => onChanged(null),
          leadingIcon: SizedBox(width: 20, child: value == null ? const Icon(AppIcons.check, size: 20) : null),
          child: Text('Any ${label.toLowerCase()}'),
        ),
        for (final o in options)
          MenuItemButton(
            onPressed: () => onChanged(o),
            leadingIcon: SizedBox(width: 20, child: o == value ? const Icon(AppIcons.check, size: 20) : null),
            child: Text(o, style: optionStyle),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton(
        onPressed: options.isEmpty ? null : () => controller.isOpen ? controller.close() : controller.open(),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          foregroundColor: selected ? c.onSecondaryContainer : c.onSurfaceVariant,
          backgroundColor: selected ? c.secondaryContainer : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[const Icon(AppIcons.check, size: 18), const SizedBox(width: 6)],
            Text(selected ? '$label: $value' : label),
            const SizedBox(width: 6),
            const Icon(AppIcons.expand, size: 18),
          ],
        ),
      ),
    );
  }
}
