import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/storage_edit.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';

/// What the dialog produces: where the node goes, and the node.
class StorageEdit {
  const StorageEdit({required this.parent, required this.node});
  final String? parent;
  final StorageNode node;

  String get path => joinPath(parent, node.key);
}

/// The types offered, with enum as its own choice (a string with choices).
enum _Type {
  string('string', 'Text'),
  enumeration('enum', 'One of a fixed list'),
  int_('int', 'Whole number'),
  number('number', 'Number'),
  bool_('bool', 'true or false'),
  array('array', 'List of values'),
  map('map', 'Group of keys'),
  any('any', 'Any JSON');

  const _Type(this.label, this.hint);
  final String label;
  final String hint;

  static _Type of(StorageNode n) => n.isEnum
      ? enumeration
      : switch (n.kind) {
          StorageKind.string => string,
          StorageKind.int => int_,
          StorageKind.number => number,
          StorageKind.bool => bool_,
          StorageKind.array => array,
          StorageKind.map => map,
          StorageKind.any => any,
        };
}

const _elementTypes = ['string', 'int', 'number', 'bool', 'any'];

/// Adds a storage path (when [path] is null) or edits the one at [path].
/// [snapdVersion] (when known) warns that secrets need snapd 2.76+.
Future<StorageEdit?> showStorageNodeDialog(
  BuildContext context, {
  required ConfdbSchema draft,
  String? path,
  String? parent,
  String? snapdVersion,
}) => showDialog<StorageEdit>(
  context: context,
  builder: (context) => _StorageNodeDialog(draft: draft, path: path, parent: parent, snapdVersion: snapdVersion),
);

/// `visibility: secret` needs snapd 2.76 or later.
bool snapdSupportsSecrets(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return true; // unknown format: don't nag
  final major = int.parse(m[1]!), minor = int.parse(m[2]!);
  return major > 2 || (major == 2 && minor >= 76);
}

class _StorageNodeDialog extends StatefulWidget {
  const _StorageNodeDialog({required this.draft, required this.path, required this.parent, required this.snapdVersion});
  final ConfdbSchema draft;
  final String? path;
  final String? parent;
  final String? snapdVersion;

  @override
  State<_StorageNodeDialog> createState() => _StorageNodeDialogState();
}

class _StorageNodeDialogState extends State<_StorageNodeDialog> {
  late final StorageNode? _original = widget.path == null ? null : widget.draft.storage.lookup(widget.path!);
  late String? _parent = widget.path == null ? widget.parent : parentOf(widget.path!);
  late final _key = TextEditingController(text: _original?.key ?? '');
  late _Type _type = _original == null ? _Type.string : _Type.of(_original);
  late final _choices = TextEditingController(text: _original?.choices.join(', ') ?? '');
  late final _pattern = TextEditingController(text: _original?.pattern ?? '');
  late final _min = TextEditingController(text: _original?.min?.toString() ?? '');
  late final _max = TextEditingController(text: _original?.max?.toString() ?? '');
  late String _elementType = _original?.valuesType ?? 'string';
  late bool _ephemeral = _original?.ephemeral ?? false;
  late bool _secret = _original?.secret ?? false;

  /// Alternative (union) types aren't edited here; only renamed.
  bool get _alternatives => _original?.raw != null;
  bool _submitted = false;

  bool get _editing => _original != null;

  @override
  void dispose() {
    for (final c in [_key, _choices, _pattern, _min, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _choiceList => [
    for (final c in _choices.text.split(','))
      if (c.trim().isNotEmpty) c.trim(),
  ];

  String? get _keyError {
    final siblings = siblingKeys(widget.draft.storage, _parent).where((k) => !_editing || k != _original!.key);
    return validateStorageKey(_key.text.trim(), siblings);
  }

  String? get _choicesError {
    if (_type != _Type.enumeration) return null;
    final list = _choiceList;
    if (list.isEmpty) return 'Enter at least one choice';
    if (list.toSet().length != list.length) return 'Choices must be different';
    return null;
  }

  String? get _patternError {
    if (_type != _Type.string || _pattern.text.isEmpty) return null;
    try {
      RegExp(_pattern.text);
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
    if (_type == _Type.int_ && v is! int) return 'Enter a whole number';
    return null;
  }

  String? get _rangeError {
    final lo = _num(_min), hi = _num(_max);
    if (lo != null && hi != null && lo > hi) return 'Min must not be above max';
    return null;
  }

  bool get _valid =>
      _keyError == null &&
      _choicesError == null &&
      _patternError == null &&
      (_type != _Type.int_ && _type != _Type.number || (_numError(_min) == null && _numError(_max) == null && _rangeError == null));

  StorageNode _build() {
    final key = _key.text.trim();
    final o = _original;
    if (o != null && o.raw != null) {
      return StorageNode(key: key, kind: o.kind, alternatives: o.alternatives, secret: o.secret, raw: o.raw);
    }
    final numeric = _type == _Type.int_ || _type == _Type.number;
    return StorageNode(
      key: key,
      kind: switch (_type) {
        _Type.string || _Type.enumeration => StorageKind.string,
        _Type.int_ => StorageKind.int,
        _Type.number => StorageKind.number,
        _Type.bool_ => StorageKind.bool,
        _Type.array => StorageKind.array,
        _Type.map => StorageKind.map,
        _Type.any => StorageKind.any,
      },
      // A map keeps its children when it stays a map.
      children: _type == _Type.map ? (_original?.isMap ?? false ? _original!.children : const []) : const [],
      choices: _type == _Type.enumeration ? _choiceList : const [],
      pattern: _type == _Type.string && _pattern.text.isNotEmpty ? _pattern.text : null,
      min: numeric ? _num(_min) : null,
      max: numeric ? _num(_max) : null,
      ephemeral: _ephemeral,
      valuesType: _type == _Type.array ? _elementType : null,
      secret: _secret,
    );
  }

  void _submit() {
    setState(() => _submitted = true);
    if (!_valid) return;
    Navigator.of(context).pop(StorageEdit(parent: _parent, node: _build()));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lostChildren = _editing && (_original!.isMap) && _type != _Type.map ? _original.walk().length : 0;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    String? shown(String? e) => _submitted || _key.text.isNotEmpty ? e : null;

    final fields = <Widget>[
      if (!_editing) ...[
        DropdownMenu<String?>(
          expandedInsets: EdgeInsets.zero,
          label: const Text('Inside'),
          initialSelection: _parent,
          textStyle: context.text.bodyLarge?.mono,
          onSelected: (v) => setState(() => _parent = v),
          dropdownMenuEntries: [for (final p in mapPaths(widget.draft.storage)) DropdownMenuEntry(value: p, label: p ?? '(top level)')],
        ),
        const SizedBox(height: 16),
      ],
      TextField(
        controller: _key,
        autofocus: true,
        style: context.text.bodyLarge?.mono,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Key',
          helper: CodeText(
            'Lowercase letters, digits and dashes · path `${joinPath(_parent, _key.text.trim().isEmpty ? '…' : _key.text.trim())}`',
            style: muted,
          ),
          errorText: shown(_keyError),
        ),
      ),
      const SizedBox(height: 16),
      DropdownMenu<_Type>(
        expandedInsets: EdgeInsets.zero,
        label: const Text('Type'),
        initialSelection: _type,
        helperText: lostChildren > 0 ? 'Its ${plural(lostChildren, 'child path')} will be removed' : _type.hint,
        onSelected: (v) => setState(() => _type = v ?? _type),
        dropdownMenuEntries: [
          for (final t in _Type.values)
            DropdownMenuEntry(
              value: t,
              label: t.label,
              trailingIcon: Text(t.hint, style: muted),
              labelWidget: Text(t.label, style: context.text.bodyLarge?.mono),
            ),
        ],
      ),
      if (_type == _Type.enumeration) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _choices,
          style: context.text.bodyLarge?.mono,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Choices',
            helperText: 'Comma-separated, e.g. 2.4GHz, 5GHz, auto',
            errorText: _submitted ? _choicesError : null,
          ),
        ),
      ],
      if (_type == _Type.string) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _pattern,
          style: context.text.bodyLarge?.mono,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Pattern (optional)',
            helperText: r'Regular expression the value must match, e.g. ^https?://',
            errorText: _patternError,
          ),
        ),
      ],
      if (_type == _Type.int_ || _type == _Type.number) ...[
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
      if (_type == _Type.array) ...[
        const SizedBox(height: 16),
        DropdownMenu<String>(
          expandedInsets: EdgeInsets.zero,
          label: const Text('Element type'),
          initialSelection: _elementType,
          onSelected: (v) => setState(() => _elementType = v ?? _elementType),
          dropdownMenuEntries: [for (final t in _elementTypes) DropdownMenuEntry(value: t, label: t)],
        ),
      ],
      if (_type == _Type.map && !_editing) ...[
        const SizedBox(height: 8),
        Text('Add keys inside it from the storage tree once it exists.', style: muted),
      ],
      const SizedBox(height: 8),
      if (_type != _Type.map)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _ephemeral,
          onChanged: (v) => setState(() => _ephemeral = v),
          title: const Text('Ephemeral'),
          subtitle: Text('Not stored; the custodian’s load-view hook provides it each time it’s read.', style: muted),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _secret,
        onChanged: (v) => setState(() => _secret = v),
        title: const Text('Secret'),
        subtitle: Text(
          _type == _Type.map
              ? 'Only admins can read it: snapd hides it and everything inside it from non-admins ("visibility": "secret").'
              : 'Only admins can read it, e.g. a password: snapd leaves it out when non-admins read ("visibility": "secret").',
          style: muted,
        ),
      ),
      if (_secret && widget.snapdVersion != null && !snapdSupportsSecrets(widget.snapdVersion!))
        InlineMessage(
          kind: MessageKind.warning,
          padding: const EdgeInsets.all(12),
          title: 'Needs snapd 2.76 or later',
          body: Text('This device runs snapd ${widget.snapdVersion}, which doesn’t know secret visibility.'),
        ),
    ];

    // Alternatives: rename only; the types are edited in the JSON view.
    final visibleFields = _alternatives
        ? [
            fields.first,
            const SizedBox(height: 16),
            InlineMessage(
              kind: MessageKind.info,
              padding: const EdgeInsets.all(12),
              title: 'Alternative types: ${_original!.typeLabel}${_original.secret ? ' · secret' : ''}',
              body: const Text('Edit the alternatives in the Storage pane’s JSON view.'),
            ),
          ]
        : fields;

    return AlertDialog(
      title: CodeText(_editing ? 'Edit `${widget.path}`' : 'Add storage path'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: visibleFields),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(_editing ? 'Save' : 'Add')),
      ],
    );
  }
}
