import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/storage_edit.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';

/// Manages a view's declared `parameters` (name, summary, presence): the
/// names a rule's field filters (`[.field={param}]`) may reference. Doesn't
/// touch any rule; assigning a parameter to a field happens per-rule, via
/// the "Filter by parameter" button on its storage path.
Future<Map<String, ParameterDef>?> showViewParametersDialog(BuildContext context, {required ViewDef view}) => showDialog<Map<String, ParameterDef>>(
  context: context,
  builder: (context) => _ViewParametersDialog(view: view),
);

class _ViewParametersDialog extends StatefulWidget {
  const _ViewParametersDialog({required this.view});
  final ViewDef view;

  @override
  State<_ViewParametersDialog> createState() => _ViewParametersDialogState();
}

class _ViewParametersDialogState extends State<_ViewParametersDialog> {
  late Map<String, ParameterDef> _parameters = {...widget.view.parameters};

  // Inline "new parameter" form state, or null when not shown.
  TextEditingController? _newName;
  TextEditingController? _newSummary;
  String _newPresence = 'optional';

  @override
  void dispose() {
    _newName?.dispose();
    _newSummary?.dispose();
    super.dispose();
  }

  void _startNewParameter() => setState(() {
    _newName = TextEditingController();
    _newSummary = TextEditingController();
    _newPresence = 'optional';
  });

  void _cancelNewParameter() => setState(() {
    _newName?.dispose();
    _newSummary?.dispose();
    _newName = null;
    _newSummary = null;
  });

  String? get _newNameError => _newName == null ? null : validateParameterName(_newName!.text.trim(), _parameters.keys);

  void _confirmNewParameter() {
    if (_newNameError != null) {
      setState(() {});
      return;
    }
    final name = _newName!.text.trim();
    final summary = _newSummary!.text.trim();
    setState(() {
      _parameters = {..._parameters, name: ParameterDef(summary: summary.isEmpty ? null : summary, presence: _newPresence)};
      _newName?.dispose();
      _newSummary?.dispose();
      _newName = null;
      _newSummary = null;
    });
  }

  void _deleteParameter(String name) => setState(() => _parameters = {..._parameters}..remove(name));

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);
    final mono = context.text.bodyMedium?.mono;

    Widget parameterRow(String name, ParameterDef def) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: mono),
                if (def.summary != null && def.summary!.isNotEmpty) Text(def.summary!, style: muted),
              ],
            ),
          ),
          DropdownMenu<String>(
            initialSelection: def.presence,
            textStyle: context.text.bodySmall,
            onSelected: (v) => setState(() => _parameters = {..._parameters, name: def.copyWith(presence: v)}),
            dropdownMenuEntries: [
              for (final p in parameterPresences) DropdownMenuEntry(value: p, label: p),
            ],
          ),
          IconButton(
            tooltip: 'Delete parameter "$name"',
            onPressed: () => _deleteParameter(name),
            icon: const Icon(AppIcons.delete, size: 20),
          ),
        ],
      ),
    );

    final newParameterForm = _newName == null
        ? Align(
            alignment: Alignment.centerLeft,
            child: TertiaryButton(label: 'New parameter', icon: AppIcons.add, onPressed: _startNewParameter),
          )
        : Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: context.colors.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _newName,
                  autofocus: true,
                  style: mono,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: 'Parameter name', errorText: _newNameError, isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _newSummary,
                  decoration: const InputDecoration(labelText: 'Summary (optional)', isDense: true),
                ),
                const SizedBox(height: 8),
                DropdownMenu<String>(
                  expandedInsets: EdgeInsets.zero,
                  label: const Text('Presence'),
                  initialSelection: _newPresence,
                  onSelected: (v) => setState(() => _newPresence = v ?? _newPresence),
                  dropdownMenuEntries: [
                    for (final p in parameterPresences) DropdownMenuEntry(value: p, label: p),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: _cancelNewParameter, child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _confirmNewParameter, child: const Text('Add')),
                  ],
                ),
              ],
            ),
          );

    return AlertDialog(
      title: Text('Parameters of "${widget.view.name}"'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Parameters a rule\'s field filters (`[.field={param}]`) can reference, to let callers narrow a storage path.',
                style: muted,
              ),
              const SizedBox(height: 12),
              if (_parameters.isEmpty) Text('None declared yet.', style: muted),
              for (final e in _parameters.entries) parameterRow(e.key, e.value),
              const SizedBox(height: 8),
              newParameterForm,
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_parameters), child: const Text('Save')),
      ],
    );
  }
}
