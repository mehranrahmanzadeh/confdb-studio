import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/storage_edit.dart';
import '../../theme/app_theme.dart';

/// What the dialog produces: the alias's name and its type definition.
class AliasEdit {
  const AliasEdit({required this.name, required this.node});
  final String name;
  final StorageNode node;
}

enum _AliasType {
  string('string', 'Text'),
  int_('int', 'Whole number'),
  number('number', 'Number'),
  bool_('bool', 'true or false'),
  any('any', 'Any JSON');

  const _AliasType(this.label, this.hint);
  final String label;
  final String hint;

  static _AliasType of(StorageNode n) => switch (n.kind) {
    StorageKind.string => string,
    StorageKind.int => int_,
    StorageKind.number => number,
    StorageKind.bool => bool_,
    StorageKind.map || StorageKind.array || StorageKind.any => any,
  };
}

/// Creates an alias (when [name] is null) or edits the one named [name].
/// Aliases are a basic (non-map, non-array) type with constraints, reused
/// across the storage schema by reference; snapd forbids `ephemeral` and
/// secret visibility on them, and they can't reference other aliases.
Future<AliasEdit?> showAliasDialog(BuildContext context, {required ConfdbSchema draft, String? name}) => showDialog<AliasEdit>(
  context: context,
  builder: (context) => _AliasDialog(draft: draft, name: name),
);

class _AliasDialog extends StatefulWidget {
  const _AliasDialog({required this.draft, required this.name});
  final ConfdbSchema draft;
  final String? name;

  @override
  State<_AliasDialog> createState() => _AliasDialogState();
}

class _AliasDialogState extends State<_AliasDialog> {
  late final StorageNode? _original = widget.name == null ? null : widget.draft.aliases[widget.name];
  late final _name = TextEditingController(text: widget.name ?? '');
  late _AliasType _type = _original == null ? _AliasType.string : _AliasType.of(_original);

  /// `string`, `int` and `number` can be restricted to a fixed list of
  /// choices instead of a pattern or a min/max range; the two are exclusive.
  late bool _useChoices = _original?.isEnum ?? false;
  late final _choices = TextEditingController(text: _original?.choices.join(', ') ?? '');
  late final _pattern = TextEditingController(text: _original?.pattern ?? '');
  late final _min = TextEditingController(text: _original?.min?.toString() ?? '');
  late final _max = TextEditingController(text: _original?.max?.toString() ?? '');
  bool _submitted = false;

  bool get _editing => widget.name != null;

  @override
  void dispose() {
    for (final c in [_name, _choices, _pattern, _min, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _choiceList => [
    for (final c in _choices.text.split(','))
      if (c.trim().isNotEmpty) c.trim(),
  ];

  String? get _nameError {
    final existing = widget.draft.aliases.keys.where((k) => !_editing || k != widget.name);
    return validateAliasName(_name.text.trim(), existing);
  }

  /// Whether the current type can be restricted to fixed choices.
  bool get _choicesAllowed => _type == _AliasType.string || _type == _AliasType.int_ || _type == _AliasType.number;

  String? get _choicesError {
    if (!_choicesAllowed || !_useChoices) return null;
    final list = _choiceList;
    if (list.isEmpty) return 'Enter at least one choice';
    if (list.toSet().length != list.length) return 'Choices must be different';
    if (_type == _AliasType.int_ && list.any((c) => int.tryParse(c) == null)) return 'Choices must be whole numbers';
    if (_type == _AliasType.number && list.any((c) => num.tryParse(c) == null)) return 'Choices must be numbers';
    return null;
  }

  String? get _patternError => _type == _AliasType.string && !_useChoices ? _regexError(_pattern.text) : null;

  static String? _regexError(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      RegExp(pattern);
      return null;
    } on FormatException catch (e) {
      return 'Not a valid pattern: ${e.message}';
    }
  }

  num? _num(TextEditingController c) => c.text.trim().isEmpty ? null : num.tryParse(c.text.trim());

  String? _numError(TextEditingController c) {
    if (c.text.trim().isEmpty) return null;
    final v = num.tryParse(c.text.trim());
    if (v == null) return 'Enter a number';
    if (_type == _AliasType.int_ && v is! int) return 'Enter a whole number';
    return null;
  }

  String? get _rangeError {
    final lo = _num(_min), hi = _num(_max);
    if (lo != null && hi != null && lo > hi) return 'Min must not be above max';
    return null;
  }

  bool get _valid =>
      _nameError == null &&
      _choicesError == null &&
      _patternError == null &&
      (_type != _AliasType.int_ && _type != _AliasType.number ||
          _useChoices ||
          (_numError(_min) == null && _numError(_max) == null && _rangeError == null));

  StorageNode _build() {
    final name = _name.text.trim();
    final numeric = _type == _AliasType.int_ || _type == _AliasType.number;
    return StorageNode(
      key: name,
      kind: switch (_type) {
        _AliasType.string => StorageKind.string,
        _AliasType.int_ => StorageKind.int,
        _AliasType.number => StorageKind.number,
        _AliasType.bool_ => StorageKind.bool,
        _AliasType.any => StorageKind.any,
      },
      choices: _choicesAllowed && _useChoices ? _choiceList : const [],
      pattern: _type == _AliasType.string && !_useChoices && _pattern.text.isNotEmpty ? _pattern.text : null,
      min: numeric && !_useChoices ? _num(_min) : null,
      max: numeric && !_useChoices ? _num(_max) : null,
    );
  }

  void _submit() {
    setState(() => _submitted = true);
    if (!_valid) return;
    Navigator.of(context).pop(AliasEdit(name: _name.text.trim(), node: _build()));
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);
    String? shown(String? e) => _submitted || _name.text.isNotEmpty ? e : null;

    final fields = <Widget>[
      TextField(
        controller: _name,
        autofocus: true,
        style: context.text.bodyLarge?.mono,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Alias name',
          helperText: 'Lowercase letters, digits and dashes, starting with a letter',
          errorText: shown(_nameError),
        ),
      ),
      const SizedBox(height: 16),
      DropdownMenu<_AliasType>(
        expandedInsets: EdgeInsets.zero,
        label: const Text('Type'),
        initialSelection: _type,
        helperText: _type.hint,
        onSelected: (v) => setState(() => _type = v ?? _type),
        dropdownMenuEntries: [
          for (final t in _AliasType.values)
            DropdownMenuEntry(
              value: t,
              label: t.label,
              trailingIcon: Text(t.hint, style: muted),
              labelWidget: Text(t.label, style: context.text.bodyLarge?.mono),
            ),
        ],
      ),
      if (_choicesAllowed) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _useChoices,
          onChanged: (v) => setState(() => _useChoices = v),
          title: const Text('Fixed choices'),
          subtitle: Text(
            'Restrict the value to a fixed list instead of ${_type == _AliasType.string ? 'a pattern' : 'a min/max range'}.',
            style: muted,
          ),
        ),
      ],
      if (_choicesAllowed && _useChoices) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _choices,
          style: context.text.bodyLarge?.mono,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Choices',
            helperText: _type == _AliasType.string
                ? 'Comma-separated, e.g. required, optional, invalid'
                : 'Comma-separated numbers, e.g. 100, 500, 800',
            errorText: _submitted ? _choicesError : null,
          ),
        ),
      ],
      if (_type == _AliasType.string && !_useChoices) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _pattern,
          style: context.text.bodyLarge?.mono,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Pattern (optional)',
            helperText: r'Regular expression the value must match, e.g. ^[a-z0-9](?:-?[a-z0-9])*$',
            errorText: _patternError,
          ),
        ),
      ],
      if ((_type == _AliasType.int_ || _type == _AliasType.number) && !_useChoices) ...[
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _min,
                style: context.text.bodyLarge?.mono,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Min (optional)', errorText: _numError(_min) ?? _rangeError),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _max,
                style: context.text.bodyLarge?.mono,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Max (optional)', errorText: _numError(_max)),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      Text(
        'Reuse this type across storage paths by its name. Aliases can’t be ephemeral, secret, or reference another alias.',
        style: muted,
      ),
    ];

    return AlertDialog(
      title: Text(_editing ? 'Edit alias "${widget.name}"' : 'Create an alias'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: fields),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(_editing ? 'Save' : 'Create')),
      ],
    );
  }
}
