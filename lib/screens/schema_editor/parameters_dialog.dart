import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/paths.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';

/// Assigns a view's declared parameters to fields of one rule's storage
/// path, as `[.field={param}]` filters on its last segment. To declare,
/// edit or remove a parameter itself, use the view's "Manage parameters".
Future<List<FieldFilter>?> showAssignFiltersDialog(
  BuildContext context, {
  required Map<String, ParameterDef> parameters,
  required List<String> fields,
  required List<FieldFilter> filters,
}) => showDialog<List<FieldFilter>>(
  context: context,
  builder: (context) => _AssignFiltersDialog(parameters: parameters, fields: fields, filters: filters),
);

class _FilterDraft {
  _FilterDraft({this.field, this.param});
  String? field;
  String? param;
}

class _AssignFiltersDialog extends StatefulWidget {
  const _AssignFiltersDialog({required this.parameters, required this.fields, required this.filters});
  final Map<String, ParameterDef> parameters;
  final List<String> fields;
  final List<FieldFilter> filters;

  @override
  State<_AssignFiltersDialog> createState() => _AssignFiltersDialogState();
}

class _AssignFiltersDialogState extends State<_AssignFiltersDialog> {
  late final _filters = [for (final f in widget.filters) _FilterDraft(field: f.field, param: f.param)];
  bool _submitted = false;

  List<String> _fieldOptions(_FilterDraft current) => [
    for (final f in widget.fields)
      if (f == current.field || !_filters.any((d) => d != current && d.field == f)) f,
  ];

  String? get _duplicateFieldError {
    final used = <String>{};
    for (final d in _filters) {
      if (d.field == null) continue;
      if (!used.add(d.field!)) return 'Each field can only be filtered once';
    }
    return null;
  }

  bool get _valid =>
      _duplicateFieldError == null && _filters.every((d) => d.field != null && d.field!.isNotEmpty && d.param != null && d.param!.isNotEmpty);

  void _addFilter() => setState(() => _filters.add(_FilterDraft()));

  void _removeFilter(_FilterDraft d) => setState(() => _filters.remove(d));

  void _submit() {
    setState(() => _submitted = true);
    if (!_valid) return;
    Navigator.of(context).pop([for (final d in _filters) FieldFilter(d.field!, d.param!)]);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);
    final mono = context.text.bodyMedium?.mono;

    Widget filterRow(_FilterDraft d) {
      final fieldOptions = _fieldOptions(d);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownMenu<String>(
                expandedInsets: EdgeInsets.zero,
                label: const Text('Field'),
                initialSelection: d.field,
                onSelected: (v) => setState(() => d.field = v),
                dropdownMenuEntries: [
                  for (final f in fieldOptions) DropdownMenuEntry(value: f, label: f, labelWidget: Text(f, style: mono)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(top: 16), child: Text('=', style: mono)),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownMenu<String>(
                expandedInsets: EdgeInsets.zero,
                label: const Text('Parameter'),
                initialSelection: d.param,
                onSelected: (v) => setState(() => d.param = v),
                dropdownMenuEntries: [
                  for (final p in widget.parameters.keys) DropdownMenuEntry(value: p, label: p, labelWidget: Text(p, style: mono)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove filter',
              onPressed: () => _removeFilter(d),
              icon: const Icon(AppIcons.delete, size: 20),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('Filter by parameter'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'A field filter (`[.field={param}]`) narrows this rule\'s storage path to entries whose field matches a parameter the caller constrains.',
                style: muted,
              ),
              const SizedBox(height: 12),
              if (widget.parameters.isEmpty)
                Text('This view has no declared parameters yet. Use "Manage parameters" to create one.', style: muted)
              else ...[
                for (final d in _filters) filterRow(d),
                if (_submitted && _duplicateFieldError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_duplicateFieldError!, style: muted?.copyWith(color: context.colors.error)),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TertiaryButton(
                    label: 'Add filter',
                    icon: AppIcons.add,
                    onPressed: _fieldOptions(_FilterDraft()).isEmpty ? null : _addFilter,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _valid ? _submit : () => setState(() => _submitted = true), child: const Text('Save')),
      ],
    );
  }
}
