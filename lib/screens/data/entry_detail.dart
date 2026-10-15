import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/paths.dart';
import '../../domain/values.dart';
import '../../shell/screen_host.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../state/staging_controller.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/status_badge.dart';
import '../access/custodian_guide.dart';
import 'data_explorer_screen.dart';
import 'view_values.dart';

/// Detail panel for one request path: metadata, editor, staged state, CLI.
class EntryDetail extends StatefulWidget {
  const EntryDetail({super.key, required this.snapshot, required this.entry, required this.ctx});

  final ViewSnapshot snapshot;
  final ViewEntry entry;
  final ExplorerContext ctx;

  @override
  State<EntryDetail> createState() => _EntryDetailState();
}

class _EntryDetailState extends State<EntryDetail> {
  late final TextEditingController _text;
  bool _touched = false;
  bool _reveal = false;

  ViewEntry get e => widget.entry;
  ViewRef get ref => widget.snapshot.ref;
  StagedValue? get _staged => _key == null ? null : context.staging.lookup(ref, _key!);

  /// One input per placeholder in the request (`{sensor}`): which entry of
  /// the collection to edit.
  late final Map<String, TextEditingController> _placeholders = {
    for (final p in placeholdersOf(e.rule.request)) p: TextEditingController(),
  };
  bool get _isCollection => _placeholders.isNotEmpty;
  Map<String, String> get _bindings => {for (final p in _placeholders.entries) p.key: p.value.text.trim()};
  bool get _bound => _bindings.entries.every((b) => isValidPlaceholderValue(e.rule.request, b.key, b.value));

  /// The concrete request path being edited; null until every placeholder is filled.
  String? get _key => !_isCollection ? e.key : (_bound ? fillPath(e.rule.request, _bindings) : null);
  String get _storagePath => _isCollection ? fillPath(e.rule.storage, _bindings) : e.rule.storage;
  StorageNode? get _node => _isCollection ? resolveStoragePath(widget.snapshot.schema.storage, _storagePath) ?? e.node : e.node;

  /// The current value at [_key]; for a collection, looked up inside it.
  Object? get _current {
    if (!_isCollection) return e.value;
    final key = _key;
    if (key == null || !e.hasValue) return null;
    final first = tryParsePath(e.rule.request)!.indexWhere((s) => s.isPlaceholder);
    return lookupValue(e.value, joinPath(parsePath(key).skip(first))).$2;
  }

  bool _syncing = false;
  Object? _lastStaged;
  late final StagingController _staging = context.staging;

  @override
  void initState() {
    super.initState();
    final staged = _key == null ? null : context.staging.lookup(ref, _key!);
    _lastStaged = staged?.value;
    _text = TextEditingController(text: _editText(staged?.value ?? (e.masked ? null : _current)));
    _text.addListener(() {
      if (!_syncing) setState(() => _touched = true);
    });
    _staging.addListener(_onStaging);
  }

  /// Follows values staged elsewhere (Retry with fix, Revert in the tray)
  /// while the user hasn't typed here.
  void _onStaging() {
    final staged = _staged;
    if (_touched || staged?.value == _lastStaged) return;
    _lastStaged = staged?.value;
    _syncing = true;
    _text.text = _editText(staged?.value ?? (e.masked ? null : _current));
    _syncing = false;
    setState(() {});
  }

  /// Another entry of the collection picked: show its value unless the
  /// user has typed one.
  void _onPlaceholder() {
    if (!_touched) {
      _lastStaged = _staged?.value;
      _syncing = true;
      _text.text = _editText(_staged?.value ?? (e.masked ? null : _current));
      _syncing = false;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _staging.removeListener(_onStaging);
    _text.dispose();
    for (final c in _placeholders.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _editText(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    return jsonEncode(v);
  }

  String? get _error => validateValue(_node, _text.text, hint: e.hint);

  bool get _differs {
    final parsed = _tryParse();
    if (parsed == null) return false;
    final staged = _staged;
    if (staged != null) return jsonEncode(parsed) != jsonEncode(staged.value) || staged.isRejected;
    return e.masked || jsonEncode(parsed) != jsonEncode(_current);
  }

  Object? _tryParse() {
    try {
      return parseInput(_node, _text.text);
    } catch (_) {
      return null;
    }
  }

  void _stage(Object? value) {
    final staging = context.staging;
    final key = _key;
    if (key == null) return;
    if (!e.masked && jsonEncode(value) == jsonEncode(_current)) {
      staging.unstage(ref, key);
      return;
    }
    staging.stage(
      StagedValue(
        view: ref,
        key: key,
        storagePath: _storagePath,
        node: _node,
        before: e.masked ? null : _current,
        value: value,
        secret: e.masked,
      ),
    );
    _lastStaged = value;
    setState(() => _touched = false);
  }

  void _revert() {
    _touched = false;
    if (_key != null) context.staging.unstage(ref, _key!);
    _syncing = true;
    _text.text = _editText(e.masked ? null : _current);
    _syncing = false;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final schema = widget.snapshot.schema;
    final staged = _staged;
    final others = otherViews(schema, ref.view, e.rule.storage);
    final custodian = custodianName(ref, widget.ctx.snaps);
    final custodianConnected = widget.ctx.snaps
        .expand((s) => s.plugs)
        .any((p) => p.role == PlugRole.custodian && p.view == ref && p.state.isConnected);
    final node = e.node;

    // Last successful change and, if newer, a failed attempt touching this path.
    final related = widget.ctx.changes
        .where((ch) => ch.view?.schemaId == ref.schemaId && ch.values.any((v) => v.storagePath == e.rule.storage))
        .toList();
    final lastDone = related.where((ch) => ch.status == ChangeStatus.done).firstOrNull;
    final lastFailed = related.where((ch) => ch.status == ChangeStatus.error).firstOrNull;
    final showAttempt = lastFailed != null && (lastDone == null || lastFailed.spawnTime.isAfter(lastDone.spawnTime));

    Widget changeLink(ConfdbChange ch) => InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: () => context.app.go(ChangeRoute(ch.id)),
      child: Text(
        '#${ch.id}',
        style: context.text.bodyMedium?.mono.copyWith(
          color: c.secondary,
          decoration: TextDecoration.underline,
          decorationColor: c.secondary,
        ),
      ),
    );

    final rows = <(String, Widget)>[
      ('Storage path', MonoText(e.rule.storage)),
      if (_isCollection)
        (
          'Entries',
          switch (e.value) {
            Map(:final keys) when e.hasValue && keys.isNotEmpty => CodeText(keys.map((k) => '`$k`').join(', ')),
            List(:final length) when e.hasValue && length > 0 => Text('$length items'),
            _ => Text('None yet', style: TextStyle(color: c.onSurfaceVariant)),
          },
        ),
      (
        'Other views',
        others.isEmpty
            ? Text('None', style: TextStyle(color: c.onSurfaceVariant))
            : Wrap(spacing: 6, runSpacing: 6, children: [for (final o in others) ViewChip(o, background: c.surfaceContainerLowest)]),
      ),
      (
        'Custodian',
        Row(
          children: [
            Icon(AppIcons.shield, size: 16, color: c.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: custodianConnected
                  ? MonoText(custodian!)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MonoText(custodian == null ? 'none connected' : '$custodian · not connected'),
                        if (!schema.builtIn) CustodianHelpLink(schema: schema, snaps: widget.ctx.snaps, short: true),
                      ],
                    ),
            ),
          ],
        ),
      ),
      if (e.hint?.description != null)
        ('Validation', Text(e.hint!.description!))
      else if (node != null && node.isEnum)
        ('Constraints', CodeText('One of ${node.choices.map((x) => '`$x`').join(', ')}'))
      else if (node?.constraintSummary != null)
        ('Constraints', Text(node!.constraintSummary!)),
      if (lastDone != null)
        (
          'Last changed',
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [changeLink(lastDone), Text(' · ${dayAndTime(lastDone.spawnTime)}')],
          ),
        ),
      if (showAttempt)
        (
          'Last attempt',
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [changeLink(lastFailed), const StatusBadge.error('Error')],
          ),
        ),
    ];

    final values = staged != null && !_touched ? staged.value : _tryParse();
    final command = e.rule.access.canWrite && _key != null
        ? snapSetCommand(ref, [(_key!, values ?? (e.masked ? '' : _current), e.masked)])
        : 'snap get ${ref.path} ${_isCollection ? fixedPrefix(e.key) : e.key}'.trimRight();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(header: true, child: Text(e.key, style: context.text.titleLarge?.mono)),
            TypeChip(e.typeLabel),
            StatusBadge.neutral(e.writeOnly ? 'write-only' : e.rule.access.label, icon: AccessLabel.iconFor(e.rule.access)),
            if (e.ephemeral) const EphemeralChip(),
            if (e.secret) const SecretChip(),
          ],
        ),
        const SizedBox(height: 16),
        DetailList(rows: rows),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        ..._editor(context, staged),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerLeft, child: CliDisclosure(command)),
      ],
    );
  }

  List<Widget> _editor(BuildContext context, StagedValue? staged) {
    final c = context.colors;
    final node = _node;
    if (!e.rule.access.canWrite) {
      return [
        InlineMessage(
          kind: MessageKind.info,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          title: 'Read-only through ${ref.view}',
          body: e.ephemeral
              ? CodeText(
                  'Loaded by `${custodianName(ref, widget.ctx.snaps) ?? 'the custodian'}`’s load-view hook each time it is read; it is never stored.',
                )
              : const Text('Pick a view with write access to change this value.'),
        ),
      ];
    }

    final widgets = <Widget>[];

    if (_isCollection) {
      widgets.addAll([
        CodeText(
          'Pick the entry to set: fill in ${_placeholders.keys.map((p) => '`{$p}`').join(' and ')}.',
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final p in _placeholders.entries)
              SizedBox(
                width: 220,
                child: TextField(
                  controller: p.value,
                  style: context.text.bodyLarge?.mono,
                  onChanged: (_) => _onPlaceholder(),
                  decoration: InputDecoration(
                    labelText: '{${p.key}}',
                    errorText: p.value.text.trim().isEmpty || isValidPlaceholderValue(e.rule.request, p.key, p.value.text.trim())
                        ? null
                        : 'Error: ${placeholderIsIndex(e.rule.request, p.key) ? 'use a list index, like 0' : 'use lowercase letters, digits and dashes'}',
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
      ]);
      if (_key == null) return widgets;
      widgets.addAll([
        CodeText('Sets `$_key` → `$_storagePath`', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: 12),
      ]);
    }

    if (node != null && node.isEnum) {
      final current = _current is String ? _current as String : null;
      final selected = (staged?.value as String?) ?? current;
      widgets.add(
        LayoutBuilder(
          builder: (context, constraints) => DropdownMenu<String>(
            key: ValueKey(_key),
            width: constraints.maxWidth,
            initialSelection: selected,
            label: const Text('Value'),
            helperText: 'One of ${node.choices.join(', ')}',
            textStyle: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
            requestFocusOnTap: false,
            onSelected: (v) => v == null ? null : _stage(v),
            dropdownMenuEntries: [
              for (final o in node.choices)
                DropdownMenuEntry(
                  value: o,
                  label: o,
                  style: MenuItemButton.styleFrom(
                    textStyle: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
                    minimumSize: const Size(0, 48),
                  ),
                  leadingIcon: SizedBox(width: 20, child: o == selected ? const Icon(AppIcons.check, size: 20) : null),
                  trailingIcon: Text(
                    o == current ? 'current' : (o == staged?.value ? 'staged' : ''),
                    style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      );
    } else {
      final error = _touched || (staged?.isRejected ?? false) ? _error : null;
      final rejected = staged?.isRejected == true && !_touched;
      final min = e.hint?.minLength;
      widgets.add(
        TextField(
          controller: _text,
          obscureText: e.masked && !_reveal,
          style: context.text.bodyLarge?.mono.copyWith(letterSpacing: e.masked && !_reveal ? 2 : null),
          maxLines: e.masked ? 1 : null,
          decoration: InputDecoration(
            labelText: e.masked ? 'New value' : 'Value',
            helperText: e.writeOnly
                ? 'Write-only: the current value can’t be read back'
                : e.secret
                ? 'Secret: snapd only shows it to admins'
                : node?.constraintSummary,
            errorText: rejected ? null : (error == null ? null : 'Error: $error'),
            error: rejected ? const SizedBox.shrink() : null,
            counterText: min != null ? '${_text.text.length} / $min' : null,
            suffixIcon: e.masked
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (error != null || rejected) Icon(AppIcons.error, color: c.error),
                      IconButton(
                        tooltip: _reveal ? 'Hide value' : 'Show value',
                        onPressed: () => setState(() => _reveal = !_reveal),
                        icon: Icon(_reveal ? AppIcons.eyeOff : AppIcons.eye),
                      ),
                      const SizedBox(width: 4),
                    ],
                  )
                : null,
          ),
        ),
      );
      if (rejected) {
        widgets.addAll([
          const SizedBox(height: 8),
          InlineMessage(
            kind: MessageKind.error,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            title: 'Rejected by ${staged!.rejectedBy ?? 'the custodian'}',
            body: CodeText('In change #${staged.fromChange}: `${staged.rejection}`'),
            actions: [
              OnContainerButton(label: 'Retry', icon: AppIcons.retry, outlined: false, onPressed: () => openReview(context)),
              OnContainerButton(label: 'View change', outlined: false, onPressed: () => context.app.go(ChangeRoute(staged.fromChange!))),
            ],
          ),
        ]);
      }
    }

    widgets.add(const SizedBox(height: 12));
    if (staged != null && !staged.isRejected && !_touched) {
      widgets.add(
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const StatusBadge.info('Staged', icon: AppIcons.edit),
            Text(
              staged.secret ? '$secretMask (hidden)' : '${staged.beforeText} → ${staged.afterText}',
              style: context.text.bodyMedium?.mono.copyWith(fontSize: 13),
            ),
            TextButton(onPressed: _revert, child: const Text('Revert')),
          ],
        ),
      );
    } else if (!(node?.isEnum ?? false)) {
      final canStage = _error == null && _differs;
      widgets.add(
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SecondaryButton(label: 'Stage change', icon: AppIcons.edit, onPressed: canStage ? () => _stage(_tryParse()) : null),
            if (staged != null) TextButton(onPressed: _revert, child: const Text('Revert')),
          ],
        ),
      );
    }
    return widgets;
  }
}
