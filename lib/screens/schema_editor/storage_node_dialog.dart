import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/storage_edit.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';

/// [path] for display: its internal `{key}` placeholder segment reads as
/// `<placeholder>`.
String _displayPath(String path) => path.replaceAll(StorageNode.placeholderKey, '<placeholder>');

/// What the dialog produces: where the node goes, and the node. For a
/// placeholder, [node] is the map's values and [keys] its key constraint.
class StorageEdit {
  const StorageEdit({required this.parent, required this.node, this.placeholder = false, this.keys});
  final String? parent;
  final StorageNode node;
  final bool placeholder;
  final StorageNode? keys;

  String get path => joinPath(parent, node.key);
}

/// The types offered. `string`, `int` and `number` can additionally be
/// restricted to a fixed list of choices (see [_choices...] in the state).
enum _Type {
  string('string', 'Text'),
  int_('int', 'Whole number'),
  number('number', 'Number'),
  bool_('bool', 'true or false'),
  array('array', 'List of values'),
  map('map', 'Group of keys'),
  any('any', 'Any JSON');

  const _Type(this.label, this.hint);
  final String label;
  final String hint;

  static _Type of(StorageNode n) => switch (n.kind) {
    StorageKind.string => string,
    StorageKind.int => int_,
    StorageKind.number => number,
    StorageKind.bool => bool_,
    StorageKind.array => array,
    StorageKind.map => map,
    StorageKind.any => any,
  };
}

const _elementTypes = ['string', 'int', 'number', 'bool', 'map', 'any'];

/// Encodes a type dropdown's entries so a plain type and an alias can share
/// one `DropdownMenu<String>`: `type:string`, `alias:gadget-name`, etc.
String _typeValue(String type) => 'type:$type';
String _aliasValue(String alias) => 'alias:$alias';

/// Adds a storage path (when [path] is null) or edits the one at [path].
/// With [placeholderOf], adds a placeholder to that map instead: any key,
/// each with a value of the chosen type. [snapdVersion] (when known) warns
/// that secrets need snapd 2.76+.
Future<StorageEdit?> showStorageNodeDialog(
  BuildContext context, {
  required ConfdbSchema draft,
  String? path,
  String? parent,
  String? placeholderOf,
  String? snapdVersion,
}) => showDialog<StorageEdit>(
  context: context,
  builder: (context) =>
      _StorageNodeDialog(draft: draft, path: path, parent: parent, placeholderOf: placeholderOf, snapdVersion: snapdVersion),
);

/// `visibility: secret` needs snapd 2.76 or later.
bool snapdSupportsSecrets(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return true; // unknown format: don't nag
  final major = int.parse(m[1]!), minor = int.parse(m[2]!);
  return major > 2 || (major == 2 && minor >= 76);
}

class _StorageNodeDialog extends StatefulWidget {
  const _StorageNodeDialog({
    required this.draft,
    required this.path,
    required this.parent,
    required this.placeholderOf,
    required this.snapdVersion,
  });
  final ConfdbSchema draft;
  final String? path;
  final String? parent;
  final String? placeholderOf;
  final String? snapdVersion;

  @override
  State<_StorageNodeDialog> createState() => _StorageNodeDialogState();
}

class _StorageNodeDialogState extends State<_StorageNodeDialog> {
  late final StorageNode? _original = widget.path == null ? null : widget.draft.storage.lookup(widget.path!);
  late String? _parent = widget.placeholderOf ?? (widget.path == null ? widget.parent : parentOf(widget.path!));

  /// Adding or editing a map's placeholder: no key name, a key pattern instead.
  late final bool _placeholder = widget.placeholderOf != null || (widget.path?.split('.').last == StorageNode.placeholderKey);
  late final StorageNode? _originalKeys = _placeholder ? widget.draft.storage.lookup(_parent!)?.keys : null;
  late final _keyPattern = TextEditingController(text: _originalKeys?.pattern ?? '');

  /// Whether the placeholder's key constraint (`"keys"`) is an alias
  /// reference rather than an inline pattern.
  late bool _keyUseAlias = _originalKeys?.aliasRef != null;
  late String? _selectedKeyAlias = _originalKeys?.aliasRef ?? widget.draft.aliases.keys.firstOrNull;
  late final _key = TextEditingController(text: _original?.key ?? '');
  late _Type _type = _original == null ? _Type.string : _Type.of(_original);

  /// `string`, `int` and `number` can be restricted to a fixed list of
  /// choices instead of a pattern or a min/max range; the two are exclusive.
  late bool _useChoices = _original?.isEnum ?? false;
  late final _choices = TextEditingController(text: _original?.choices.join(', ') ?? '');
  late final _pattern = TextEditingController(text: _original?.pattern ?? '');
  late final _min = TextEditingController(text: _original?.min?.toString() ?? '');
  late final _max = TextEditingController(text: _original?.max?.toString() ?? '');
  late String _elementType = (_original?.element?.isMap ?? false) ? 'map' : (_original?.valuesType ?? 'string');
  late bool _ephemeral = _original?.ephemeral ?? false;
  late bool _secret = _original?.secret ?? false;

  /// An array element can be restricted to fixed choices too, mirroring
  /// [_useChoices]/[_choices]/[_pattern]/[_min]/[_max] but for the element
  /// type instead of the node's own type.
  late bool _elementUseChoices = _original?.element?.isEnum ?? false;
  late final _elementChoices = TextEditingController(text: _original?.element?.choices.join(', ') ?? '');
  late final _elementPattern = TextEditingController(text: _original?.element?.pattern ?? '');
  late final _elementMin = TextEditingController(text: _original?.element?.min?.toString() ?? '');
  late final _elementMax = TextEditingController(text: _original?.element?.max?.toString() ?? '');

  /// Whether an array's elements are themselves an alias rather than an
  /// inline type.
  late bool _elementUseAlias = _original?.element?.aliasRef != null;
  late String? _selectedElementAlias = _original?.element?.aliasRef ?? widget.draft.aliases.keys.firstOrNull;

  /// `"unique"`: no two of an array's elements may be equal.
  late bool _unique = _original?.unique ?? false;

  /// Required key combinations for a map with fixed children (`"schema"`):
  /// each entry is one allowed combination; at least one must be fully
  /// present. Only editable for an existing map with children, since new
  /// maps start with no keys to require.
  late final List<Set<String>> _required = [for (final combo in _original?.required ?? const []) combo.toSet()];

  /// Whether the type is an existing alias rather than an inline type.
  late bool _useAlias = _original?.aliasRef != null;
  late String? _selectedAlias = _original?.aliasRef ?? widget.draft.aliases.keys.firstOrNull;

  /// The combined Type dropdown's current value: a plain type or an alias.
  String get _typeSelection => _useAlias && _selectedAlias != null ? _aliasValue(_selectedAlias!) : _typeValue(_type.name);

  void _onTypeSelected(String? v) {
    if (v == null) return;
    setState(() {
      if (v.startsWith('alias:')) {
        _useAlias = true;
        _selectedAlias = v.substring('alias:'.length);
      } else {
        _useAlias = false;
        _type = _Type.values.firstWhere((t) => t.name == v.substring('type:'.length));
      }
    });
  }

  /// The placeholder's key-constraint dropdown's current value: a custom
  /// pattern or an alias, mirroring [_typeSelection].
  String get _keyTypeSelection => _keyUseAlias && _selectedKeyAlias != null ? _aliasValue(_selectedKeyAlias!) : _typeValue('string');

  void _onKeyTypeSelected(String? v) {
    if (v == null) return;
    setState(() {
      if (v.startsWith('alias:')) {
        _keyUseAlias = true;
        _selectedKeyAlias = v.substring('alias:'.length);
      } else {
        _keyUseAlias = false;
      }
    });
  }

  /// The combined Element type dropdown's current value, mirroring [_typeSelection].
  String get _elementTypeSelection =>
      _elementUseAlias && _selectedElementAlias != null ? _aliasValue(_selectedElementAlias!) : _typeValue(_elementType);

  void _onElementTypeSelected(String? v) {
    if (v == null) return;
    setState(() {
      if (v.startsWith('alias:')) {
        _elementUseAlias = true;
        _selectedElementAlias = v.substring('alias:'.length);
      } else {
        _elementUseAlias = false;
        _elementType = v.substring('type:'.length);
      }
    });
  }

  /// Alternative (union) types aren't edited here; only renamed.
  bool get _alternatives => _original?.raw != null;
  bool _submitted = false;

  bool get _editing => _original != null;

  @override
  void dispose() {
    for (final c in [_key, _choices, _pattern, _min, _max, _keyPattern, _elementChoices, _elementPattern, _elementMin, _elementMax]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _choiceList => [
    for (final c in _choices.text.split(','))
      if (c.trim().isNotEmpty) c.trim(),
  ];

  List<String> get _elementChoiceList => [
    for (final c in _elementChoices.text.split(','))
      if (c.trim().isNotEmpty) c.trim(),
  ];

  /// Editing an existing map with fixed keys (not a placeholder): the only
  /// shape `"required"` applies to.
  bool get _showRequired => _type == _Type.map && _editing && (_original?.isMap ?? false) && !_original!.hasPlaceholder;

  List<String> get _requiredKeys => [for (final c in _original?.children ?? const <StorageNode>[]) c.key];

  List<List<String>> get _requiredCombos => [
    for (final combo in _required)
      if (combo.isNotEmpty) combo.toList(),
  ];

  String? get _keyError {
    if (_placeholder) return null;
    final siblings = siblingKeys(widget.draft.storage, _parent).where((k) => !_editing || k != _original!.key);
    return validateStorageKey(_key.text.trim(), siblings);
  }

  /// Whether the current type can be restricted to fixed choices.
  bool get _choicesAllowed => _type == _Type.string || _type == _Type.int_ || _type == _Type.number;

  String? get _choicesError {
    if (!_choicesAllowed || !_useChoices) return null;
    final list = _choiceList;
    if (list.isEmpty) return 'Enter at least one choice';
    if (list.toSet().length != list.length) return 'Choices must be different';
    if (_type == _Type.int_ && list.any((c) => int.tryParse(c) == null)) return 'Choices must be whole numbers';
    if (_type == _Type.number && list.any((c) => num.tryParse(c) == null)) return 'Choices must be numbers';
    return null;
  }

  String? get _patternError => _type == _Type.string && !_useChoices ? _regexError(_pattern.text) : null;

  /// Whether the array's element type can be restricted to fixed choices
  /// (mirrors [_choicesAllowed] but for [_elementType]).
  bool get _elementChoicesAllowed =>
      _type == _Type.array && !_elementUseAlias && (_elementType == 'string' || _elementType == 'int' || _elementType == 'number');

  String? get _elementChoicesError {
    if (!_elementChoicesAllowed || !_elementUseChoices) return null;
    final list = _elementChoiceList;
    if (list.isEmpty) return 'Enter at least one choice';
    if (list.toSet().length != list.length) return 'Choices must be different';
    if (_elementType == 'int' && list.any((c) => int.tryParse(c) == null)) return 'Choices must be whole numbers';
    if (_elementType == 'number' && list.any((c) => num.tryParse(c) == null)) return 'Choices must be numbers';
    return null;
  }

  String? get _elementPatternError =>
      _elementChoicesAllowed && _elementType == 'string' && !_elementUseChoices ? _regexError(_elementPattern.text) : null;

  static String? _regexError(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      RegExp(pattern);
      return null;
    } on FormatException catch (e) {
      return 'Not a valid pattern: ${e.message}';
    }
  }

  /// The `"keys"` constraint: a string with the pattern, or none. Keys
  /// defined some other way (choices…) are kept while the pattern is untouched.
  StorageNode? get _keys {
    if (_keyUseAlias && _selectedKeyAlias != null) {
      return widget.draft.aliases[_selectedKeyAlias]!.asAliasRef('keys', _selectedKeyAlias!);
    }
    final p = _keyPattern.text.trim();
    if (_originalKeys != null && _originalKeys.aliasRef == null && p == (_originalKeys.pattern ?? '')) return _originalKeys;
    return p.isEmpty ? null : StorageNode(key: 'keys', kind: StorageKind.string, pattern: p);
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

  String? _elementNumError(TextEditingController c) {
    if (c.text.trim().isEmpty) return null;
    final v = num.tryParse(c.text.trim());
    if (v == null) return 'Enter a number';
    if (_elementType == 'int' && v is! int) return 'Enter a whole number';
    return null;
  }

  String? get _elementRangeError {
    final lo = _num(_elementMin), hi = _num(_elementMax);
    if (lo != null && hi != null && lo > hi) return 'Min must not be above max';
    return null;
  }

  bool get _valid =>
      _keyError == null &&
      (!_placeholder || (_keyUseAlias ? _selectedKeyAlias != null : _regexError(_keyPattern.text.trim()) == null)) &&
      (_useAlias
          ? _selectedAlias != null
          : _choicesError == null &&
                _patternError == null &&
                (_type != _Type.int_ && _type != _Type.number ||
                    _useChoices ||
                    (_numError(_min) == null && _numError(_max) == null && _rangeError == null)) &&
                (_type != _Type.array || !_elementUseAlias || _selectedElementAlias != null) &&
                (!_elementChoicesAllowed ||
                    (_elementChoicesError == null &&
                        _elementPatternError == null &&
                        (_elementType != 'int' && _elementType != 'number' ||
                            _elementUseChoices ||
                            (_elementNumError(_elementMin) == null &&
                                _elementNumError(_elementMax) == null &&
                                _elementRangeError == null)))));

  /// The array's element type: an alias reference, a nested map (keeping its
  /// existing children when it was already a map), or a scalar type.
  StorageNode _buildElement() {
    if (_elementUseAlias && _selectedElementAlias != null) {
      return widget.draft.aliases[_selectedElementAlias]!.asAliasRef(StorageNode.placeholderKey, _selectedElementAlias!);
    }
    if (_elementType == 'map') {
      final existing = _original?.kind == StorageKind.array ? _original!.element : null;
      if (existing != null && existing.isMap && existing.aliasRef == null) return existing;
      return const StorageNode(key: StorageNode.placeholderKey, kind: StorageKind.map);
    }
    final elementNumeric = _elementType == 'int' || _elementType == 'number';
    return StorageNode(
      key: StorageNode.placeholderKey,
      kind: StorageKind.values.where((k) => k.name == _elementType).firstOrNull ?? StorageKind.any,
      choices: _elementChoicesAllowed && _elementUseChoices ? _elementChoiceList : const [],
      pattern: _elementChoicesAllowed && _elementType == 'string' && !_elementUseChoices && _elementPattern.text.isNotEmpty
          ? _elementPattern.text
          : null,
      min: elementNumeric && !_elementUseChoices ? _num(_elementMin) : null,
      max: elementNumeric && !_elementUseChoices ? _num(_elementMax) : null,
    );
  }

  StorageNode _build() {
    final key = _placeholder ? StorageNode.placeholderKey : _key.text.trim();
    final o = _original;
    if (o != null && o.raw != null) {
      return StorageNode(key: key, kind: o.kind, alternatives: o.alternatives, secret: o.secret, raw: o.raw);
    }
    if (_useAlias && _selectedAlias != null) {
      return widget.draft.aliases[_selectedAlias]!.asAliasRef(key, _selectedAlias!);
    }
    final numeric = _type == _Type.int_ || _type == _Type.number;
    final node = StorageNode(
      key: key,
      kind: switch (_type) {
        _Type.string => StorageKind.string,
        _Type.int_ => StorageKind.int,
        _Type.number => StorageKind.number,
        _Type.bool_ => StorageKind.bool,
        _Type.array => StorageKind.array,
        _Type.map => StorageKind.map,
        _Type.any => StorageKind.any,
      },
      // A map keeps its children when it stays a map.
      children: _type == _Type.map ? (_original?.isMap ?? false ? _original!.children : const []) : const [],
      choices: _choicesAllowed && _useChoices ? _choiceList : const [],
      pattern: _type == _Type.string && !_useChoices && _pattern.text.isNotEmpty ? _pattern.text : null,
      min: numeric && !_useChoices ? _num(_min) : null,
      max: numeric && !_useChoices ? _num(_max) : null,
      ephemeral: _ephemeral,
      secret: _secret,
      required: _showRequired ? _requiredCombos : const [],
      unique: _type == _Type.array && _unique,
    );
    if (_type == _Type.array) return node.withElement(_buildElement());
    // A map keeps its placeholder (and key constraint) when it stays a map.
    final o2 = _original;
    if (_type == _Type.map && o2 != null && o2.isMap) return node.withElement(o2.hasPlaceholder ? o2.element : null).withKeys(o2.keys);
    return node;
  }

  void _submit() {
    setState(() => _submitted = true);
    if (!_valid) return;
    Navigator.of(context).pop(StorageEdit(parent: _parent, node: _build(), placeholder: _placeholder, keys: _placeholder ? _keys : null));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lostChildren = _editing && (_original!.isMap) && _type != _Type.map ? _original.walk().length : 0;
    final lostElementChildren =
        _editing && _type == _Type.array && (_original!.element?.isMap ?? false) && !_elementUseAlias && _elementType != 'map'
        ? _original.element!.walk().length
        : 0;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    String? shown(String? e) => _submitted || _key.text.isNotEmpty ? e : null;

    final fields = <Widget>[
      if (_placeholder) ...[
        CodeText(
          'Lets `${_displayPath(_parent ?? '')}` hold any key. Views name it in their paths, e.g. `$_parent.{name}`, and every key’s value has the type below.',
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        DropdownMenu<String>(
          expandedInsets: EdgeInsets.zero,
          label: const Text('Key type'),
          initialSelection: _keyTypeSelection,
          helperText: _keyUseAlias ? null : 'Keys must match a pattern, or any key when left blank.',
          onSelected: _onKeyTypeSelected,
          dropdownMenuEntries: [
            DropdownMenuEntry(
              value: _typeValue('string'),
              label: 'Pattern',
              labelWidget: Text('Pattern', style: context.text.bodyLarge?.mono),
            ),
            for (final e in widget.draft.aliases.entries.where((e) => e.value.kind == StorageKind.string))
              DropdownMenuEntry(
                value: _aliasValue(e.key),
                label: e.key,
                trailingIcon: Text(e.value.typeLabel, style: muted),
                labelWidget: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e.key, style: context.text.bodyLarge?.mono),
                    const SizedBox(width: 6),
                    const TypeChip('alias'),
                  ],
                ),
              ),
          ],
        ),
        if (!_keyUseAlias) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _keyPattern,
            autofocus: true,
            style: context.text.bodyLarge?.mono,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Placeholder pattern (optional)',
              helperText: r'Regular expression placeholders must match, e.g. ^[a-z](?:-?[a-z0-9])*$ · written as "keys"',
              helperMaxLines: 2,
              errorText: _regexError(_keyPattern.text.trim()),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ] else if (!_editing) ...[
        DropdownMenu<String?>(
          expandedInsets: EdgeInsets.zero,
          label: const Text('Inside'),
          initialSelection: _parent,
          textStyle: context.text.bodyLarge?.mono,
          onSelected: (v) => setState(() => _parent = v),
          dropdownMenuEntries: [
            for (final p in mapPaths(widget.draft.storage)) DropdownMenuEntry(value: p, label: p == null ? '(top level)' : _displayPath(p)),
          ],
        ),
        const SizedBox(height: 16),
      ],
      if (!_placeholder) ...[
        TextField(
          controller: _key,
          autofocus: true,
          style: context.text.bodyLarge?.mono,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Key',
            helper: CodeText(
              'Lowercase letters, digits and dashes · path `${_displayPath(joinPath(_parent, _key.text.trim().isEmpty ? '…' : _key.text.trim()))}`',
              style: muted,
            ),
            errorText: shown(_keyError),
          ),
        ),
        const SizedBox(height: 16),
      ],
      DropdownMenu<String>(
        expandedInsets: EdgeInsets.zero,
        label: Text(_placeholder ? 'Value type' : 'Type'),
        initialSelection: _typeSelection,
        helperText: _useAlias
            ? null
            : lostChildren > 0
            ? 'Its ${plural(lostChildren, 'child path')} will be removed'
            : _type.hint,
        onSelected: _onTypeSelected,
        dropdownMenuEntries: [
          for (final t in _Type.values)
            DropdownMenuEntry(
              value: _typeValue(t.name),
              label: t.label,
              trailingIcon: Text(t.hint, style: muted),
              labelWidget: Text(t.label, style: context.text.bodyLarge?.mono),
            ),
          for (final e in widget.draft.aliases.entries)
            DropdownMenuEntry(
              value: _aliasValue(e.key),
              label: e.key,
              trailingIcon: Text(e.value.typeLabel, style: muted),
              labelWidget: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(e.key, style: context.text.bodyLarge?.mono),
                  const SizedBox(width: 6),
                  const TypeChip('alias'),
                ],
              ),
            ),
        ],
      ),
      if (!_useAlias) ...[
        if (_choicesAllowed) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useChoices,
            onChanged: (v) => setState(() => _useChoices = v),
            title: const Text('Fixed choices'),
            subtitle: Text(
              'Restrict the value to a fixed list instead of ${_type == _Type.string ? 'a pattern' : 'a min/max range'}.',
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
              helperText: _type == _Type.string
                  ? 'Comma-separated, e.g. 2.4GHz, 5GHz, auto'
                  : 'Comma-separated numbers, e.g. 100, 500, 800',
              errorText: _submitted ? _choicesError : null,
            ),
          ),
        ],
        if (_type == _Type.string && !_useChoices) ...[
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
        if ((_type == _Type.int_ || _type == _Type.number) && !_useChoices) ...[
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
            initialSelection: _elementTypeSelection,
            helperText: !_elementUseAlias && lostElementChildren > 0 ? 'Its ${plural(lostElementChildren, 'field')} will be removed' : null,
            onSelected: _onElementTypeSelected,
            dropdownMenuEntries: [
              for (final t in _elementTypes) DropdownMenuEntry(value: _typeValue(t), label: t),
              for (final e in widget.draft.aliases.entries)
                DropdownMenuEntry(
                  value: _aliasValue(e.key),
                  label: e.key,
                  trailingIcon: Text(e.value.typeLabel, style: muted),
                  labelWidget: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(e.key, style: context.text.bodyLarge?.mono),
                      const SizedBox(width: 6),
                      const TypeChip('alias'),
                    ],
                  ),
                ),
            ],
          ),
          if (!_elementUseAlias) ...[
            if (_elementType == 'map') ...[
              const SizedBox(height: 8),
              Text('Add fields inside each element from the storage tree once it exists.', style: muted),
            ] else if (_elementChoicesAllowed) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _elementUseChoices,
                onChanged: (v) => setState(() => _elementUseChoices = v),
                title: const Text('Fixed choices'),
                subtitle: Text(
                  'Restrict each element to a fixed list instead of ${_elementType == 'string' ? 'a pattern' : 'a min/max range'}.',
                  style: muted,
                ),
              ),
              if (_elementUseChoices) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _elementChoices,
                  style: context.text.bodyLarge?.mono,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Choices',
                    helperText: _elementType == 'string'
                        ? 'Comma-separated, e.g. 2.4GHz, 5GHz, auto'
                        : 'Comma-separated numbers, e.g. 100, 500, 800',
                    errorText: _submitted ? _elementChoicesError : null,
                  ),
                ),
              ],
              if (_elementType == 'string' && !_elementUseChoices) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _elementPattern,
                  style: context.text.bodyLarge?.mono,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Pattern (optional)',
                    helperText: r'Regular expression each element must match, e.g. ^https?://',
                    errorText: _elementPatternError,
                  ),
                ),
              ],
              if ((_elementType == 'int' || _elementType == 'number') && !_elementUseChoices) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _elementMin,
                        style: context.text.bodyLarge?.mono,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Min (optional)',
                          errorText: _elementNumError(_elementMin) ?? _elementRangeError,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _elementMax,
                        style: context.text.bodyLarge?.mono,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(labelText: 'Max (optional)', errorText: _elementNumError(_elementMax)),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _unique,
            onChanged: (v) => setState(() => _unique = v),
            title: const Text('Unique'),
            subtitle: Text('No two elements may be equal.', style: muted),
          ),
        ],
        if (_type == _Type.map && !_editing) ...[
          const SizedBox(height: 8),
          Text(
            _placeholder
                ? 'Add the keys each value holds from the storage tree once it exists.'
                : 'Add keys inside it, or a placeholder for any key, from the storage tree once it exists.',
            style: muted,
          ),
        ],
        if (_showRequired) ...[
          const SizedBox(height: 16),
          Text('Required keys', style: context.text.labelLarge),
          Text('At least one combination below must be fully present. Leave empty for no requirement.', style: muted),
          const SizedBox(height: 8),
          for (var i = 0; i < _required.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final k in _requiredKeys)
                          FilterChip(
                            label: Text(k, style: context.text.bodySmall?.mono),
                            selected: _required[i].contains(k),
                            onSelected: (v) => setState(() => v ? _required[i].add(k) : _required[i].remove(k)),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove combination',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _required.removeAt(i)),
                    icon: const Icon(AppIcons.delete, size: 18),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _required.add({})),
              icon: const Icon(AppIcons.add, size: 18),
              label: Text(_required.isEmpty ? 'Require some keys' : 'Add alternative combination'),
            ),
          ),
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
      ],
      if (!_useAlias)
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
      title: CodeText(
        _placeholder
            ? (_editing ? 'Edit placeholder `${_displayPath(widget.path!)}`' : 'Add placeholder to `${_displayPath(_parent ?? '')}`')
            : (_editing ? 'Edit `${_displayPath(widget.path!)}`' : 'Add storage path'),
      ),
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
