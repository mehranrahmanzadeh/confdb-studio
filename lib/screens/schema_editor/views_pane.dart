import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';

final _viewName = RegExp(r'^[a-z0-9](-?[a-z0-9])*$');

/// Validates a view name, ignoring a clash with [ignoring] itself (the
/// view's current name, when renaming an existing view).
String? validateViewName(String name, ConfdbSchema draft, {String? ignoring}) {
  if (name.isEmpty) return 'Enter a name';
  if (!_viewName.hasMatch(name)) return 'Lowercase letters, digits and single dashes';
  if (name != ignoring && draft.view(name) != null) return 'A view with this name exists';
  return null;
}

/// Left pane of the editor: views with their rules, and "Add view".
class ViewsPane extends StatefulWidget {
  const ViewsPane({
    super.key,
    required this.draft,
    required this.selected,
    required this.issues,
    required this.onSelect,
    required this.onAdd,
  });
  final ConfdbSchema draft;
  final String? selected;
  final List<LintIssue> issues;
  final void Function(String view, {String? rule}) onSelect;
  final ValueChanged<String> onAdd;

  @override
  State<ViewsPane> createState() => _ViewsPaneState();
}

class _ViewsPaneState extends State<ViewsPane> {
  bool _adding = false;
  final _name = TextEditingController();
  String? _error;

  /// Views whose rules are collapsed even while selected (toggled through
  /// the expand/collapse arrow); absent means expanded by default.
  final _collapsed = <String>{};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final error = validateViewName(name, widget.draft);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    widget.onAdd(name);
    setState(() {
      _adding = false;
      _error = null;
      _name.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final views = widget.draft.views;
    return Container(
      decoration: BoxDecoration(color: c.surfaceContainerLow),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(header: true, child: Text('Views', style: context.text.titleSmall)),
                  ),
                  Text('${views.length}', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final v in views) _view(context, v),
          const SizedBox(height: 8),
          if (_adding)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TextField(
                controller: _name,
                autofocus: true,
                style: context.text.bodyMedium?.mono,
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                decoration: InputDecoration(
                  labelText: 'View name',
                  helperText: 'Lowercase letters, digits and dashes',
                  errorText: _error,
                  suffixIcon: IconButton(tooltip: 'Add', onPressed: _submit, icon: const Icon(AppIcons.check)),
                ),
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TertiaryButton(label: 'Add view', icon: AppIcons.add, onPressed: () => setState(() => _adding = true)),
            ),
        ],
      ),
    );
  }

  Widget _view(BuildContext context, ViewDef v) {
    final c = context.colors;
    final sel = v.name == widget.selected;
    final expanded = sel && !_collapsed.contains(v.name);
    final fg = sel ? c.onSecondaryContainer : c.onSurface;
    final badRules = {
      for (final i in widget.issues)
        if (i.isError && i.view == v.name) i.request,
    };
    void toggle() => setState(() {
      if (sel) {
        if (!_collapsed.remove(v.name)) _collapsed.add(v.name);
      } else {
        _collapsed.remove(v.name);
        widget.onSelect(v.name);
      }
    });
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            selected: sel,
            expanded: expanded,
            child: Material(
              color: sel ? c.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                mouseCursor: WidgetStateMouseCursor.clickable,
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onSelect(v.name),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                    child: Row(
                      children: [
                        Semantics(
                          button: true,
                          container: true,
                          label: '${expanded ? 'Collapse' : 'Expand'} ${v.name}',
                          excludeSemantics: true,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: toggle,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(expanded ? AppIcons.expand : AppIcons.chevronRight, size: 18, color: fg),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                v.name,
                                style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500, color: fg),
                              ),
                              Text(
                                v.access.label,
                                style: context.text.bodySmall?.copyWith(color: sel ? c.onSecondaryContainer : c.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        CountPill(
                          v.rules.length,
                          semanticLabel: '${v.rules.length} rules',
                          background: sel ? c.onSecondaryContainer.withValues(alpha: 0.14) : null,
                          foreground: fg,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (expanded)
            // Rules as a small nested tree: a guide line under the view, then
            // each request path with the storage path it maps to beneath it.
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 0, 6),
              padding: const EdgeInsets.only(left: 6),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: c.outlineVariant)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final r in v.rules) _rule(context, v, r, bad: badRules.contains(r.request))],
              ),
            ),
        ],
      ),
    );
  }

  Widget _rule(BuildContext context, ViewDef v, ViewRule r, {required bool bad}) {
    final c = context.colors;
    final request = r.request.isEmpty ? '(no request path)' : r.request;
    final storage = r.storage.isEmpty ? '(no storage path)' : r.storage;
    return Semantics(
      button: true,
      label: '$request maps to $storage${bad ? ', lint error: storage path does not exist' : ''}',
      excludeSemantics: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        borderRadius: BorderRadius.circular(6),
        onTap: () => widget.onSelect(v.name, rule: r.request),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      request,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.mono.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: bad ? c.error : c.onSurface,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.subdirectory_arrow_right, size: 12, color: c.onSurfaceVariant),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            bad ? '$storage · missing' : storage,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelSmall?.mono.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: bad ? c.error : c.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (bad) ...[const SizedBox(width: 6), Icon(AppIcons.error, size: 16, color: c.error)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact layout: a select instead of the views pane.
class ViewsSelect extends StatelessWidget {
  const ViewsSelect({
    super.key,
    required this.draft,
    required this.selected,
    required this.issues,
    required this.onSelect,
    required this.onAdd,
  });
  final ConfdbSchema draft;
  final String? selected;
  final List<LintIssue> issues;
  final void Function(String view, {String? rule}) onSelect;
  final ValueChanged<String> onAdd;

  Future<void> _addView(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _AddViewDialog(draft: draft),
    );
    if (name != null) onAdd(name);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 420,
          child: OutlinedSelect<String>(
            label: 'View',
            items: [
              for (final v in draft.views)
                (
                  v.name,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(v.name, style: context.text.bodyMedium?.mono),
                      const SizedBox(width: 12),
                      Text(
                        '${v.access.label} · ${v.rules.length} rules',
                        style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                      ),
                      if (issues.any((i) => i.isError && i.view == v.name)) ...[
                        const SizedBox(width: 8),
                        Icon(AppIcons.error, size: 16, color: c.error),
                      ],
                    ],
                  ),
                ),
            ],
            onSelected: (v) => onSelect(v),
            child: Text(selected ?? 'No views'),
          ),
        ),
        TertiaryButton(label: 'Add view', icon: AppIcons.add, onPressed: () => _addView(context)),
      ],
    );
  }
}

class _AddViewDialog extends StatefulWidget {
  const _AddViewDialog({required this.draft});
  final ConfdbSchema draft;

  @override
  State<_AddViewDialog> createState() => _AddViewDialogState();
}

class _AddViewDialogState extends State<_AddViewDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final error = validateViewName(name, widget.draft);
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.of(context).pop(name);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add view'),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _name,
        autofocus: true,
        style: context.text.bodyMedium?.mono,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(labelText: 'View name', helperText: 'Lowercase letters, digits and dashes', errorText: _error),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: _submit, child: const Text('Add view')),
    ],
  );
}
