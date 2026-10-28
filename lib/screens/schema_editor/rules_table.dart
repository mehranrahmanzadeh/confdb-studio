import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/paths.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import 'parameters_dialog.dart';

/// Rules of one view: request path → storage path, access. ComponentSheet
/// "Rule table row" states: default, editing (focused), error.
class RulesTable extends StatefulWidget {
  const RulesTable({
    super.key,
    required this.view,
    required this.storage,
    required this.usage,
    required this.issues,
    required this.focusRule,
    required this.selectedStoragePath,
    required this.onStoragePathSelected,
    required this.onChanged,
    required this.onQuickFix,
  });

  final ViewDef view;
  final StorageNode storage;

  /// Number of views that map each storage path.
  final Map<String, int> usage;

  /// Lint issues of this view.
  final List<LintIssue> issues;
  final String? focusRule;
  final String? selectedStoragePath;
  final ValueChanged<String> onStoragePathSelected;
  final ValueChanged<List<ViewRule>> onChanged;
  final void Function(String path, StorageNode leaf) onQuickFix;

  @override
  State<RulesTable> createState() => _RulesTableState();
}

class _RulesTableState extends State<RulesTable> {
  final _req = <TextEditingController>[];
  final _store = <TextEditingController>[];
  final _reqFocus = <FocusNode>[];
  final _storeFocus = <FocusNode>[];
  String? _focused;

  List<ViewRule> get rules => widget.view.rules;

  @override
  void initState() {
    super.initState();
    _sync();
    _focusRequested();
  }

  @override
  void didUpdateWidget(RulesTable old) {
    super.didUpdateWidget(old);
    _sync();
    if (widget.focusRule != old.focusRule) _focusRequested();
  }

  /// Keeps one controller pair per rule, without disturbing the one being typed in.
  void _sync() {
    while (_req.length < rules.length) {
      _req.add(TextEditingController());
      _store.add(TextEditingController());
      _reqFocus.add(FocusNode());
      _storeFocus.add(FocusNode());
    }
    while (_req.length > rules.length) {
      _req.removeLast().dispose();
      _store.removeLast().dispose();
      _reqFocus.removeLast().dispose();
      _storeFocus.removeLast().dispose();
    }
    for (var i = 0; i < rules.length; i++) {
      if (_req[i].text != rules[i].request) _req[i].text = rules[i].request;
      if (_store[i].text != rules[i].storage) _store[i].text = rules[i].storage;
    }
  }

  void _focusRequested() {
    final target = widget.focusRule;
    if (target == null || target == _focused) return;
    _focused = target;
    final i = rules.indexWhere((r) => r.request == target);
    if (i < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i >= _storeFocus.length) return;
      final bad = widget.issues.any((x) => x.isError && x.request == target && x.storagePath != null);
      (bad ? _storeFocus[i] : _reqFocus[i]).requestFocus();
    });
  }

  @override
  void dispose() {
    for (final x in [..._req, ..._store]) {
      x.dispose();
    }
    for (final f in [..._reqFocus, ..._storeFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _reorder(int oldIndex, int newIndex) {
    final updated = [...rules];
    final moved = updated.removeAt(oldIndex);
    updated.insert(newIndex, moved);
    // Deferred: ReorderableListView is still settling its own drag-end
    // rebuild/layout pass when this callback fires. Applying the data change
    // (and the resulting controller `_sync`) in the same frame can touch a
    // rule row's TextEditingController while its EditableText element is
    // momentarily inactive mid-transition, so wait for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(updated);
    });
  }

  void _set(int i, ViewRule rule) => widget.onChanged([for (var j = 0; j < rules.length; j++) j == i ? rule : rules[j]]);

  void _delete(int i) => widget.onChanged([
    for (var j = 0; j < rules.length; j++)
      if (j != i) rules[j],
  ]);

  int? get _focusedRuleIndex {
    for (var i = 0; i < rules.length; i++) {
      if (_reqFocus[i].hasFocus || _storeFocus[i].hasFocus) return i;
    }
    return null;
  }

  void _deleteFocusedRule() {
    final index = _focusedRuleIndex;
    if (index == null) return;
    _delete(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reqFocus.isNotEmpty) _reqFocus[index.clamp(0, _reqFocus.length - 1)].requestFocus();
    });
  }

  void _moveFocusedRule(int offset) {
    final index = _focusedRuleIndex;
    if (index == null || rules.length < 2) return;
    final target = (index + offset).clamp(0, rules.length - 1);
    if (target == index) return;
    _reorder(index, target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && target < _reqFocus.length) _reqFocus[target].requestFocus();
      });
    });
  }

  void _add() {
    widget.onChanged([...rules, const ViewRule(request: '', storage: '', access: RuleAccess.read)]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reqFocus.isNotEmpty) _reqFocus.last.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final head = tableHeaderStyle(context);
    Widget cells(Widget a, Widget b, Widget fields, Widget d, Widget e) => Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 8, child: a),
        const SizedBox(width: 12),
        Expanded(flex: 16, child: b),
        const SizedBox(width: 12),
        SizedBox(width: 140, child: fields),
        const SizedBox(width: 12),
        SizedBox(width: 150, child: d),
        const SizedBox(width: 12),
        SizedBox(width: 40, child: e),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.backspace, control: true): _deleteFocusedRule,
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _moveFocusedRule(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _moveFocusedRule(1),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: 'Rules of ${widget.view.name}',
            container: true,
            child: SectionCard(
              radius: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.fromLTRB(0, 0, 4, 0),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        const SizedBox(width: 24),
                        Expanded(
                          child: cells(
                            Text('Request path', style: head),
                            Text('Storage path', style: head),
                            Text('Fields', style: head),
                            Text('Access', style: head),
                            Semantics(label: 'Actions', child: const SizedBox.shrink()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (rules.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.outlineVariant)),
                      ),
                      child: Text(
                        'No rules yet. Add one to expose a storage path through this view.',
                        style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                      ),
                    )
                  else
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) => Material(color: c.surfaceContainerHigh, elevation: 4, child: child),
                      itemCount: rules.length,
                      onReorderItem: _reorder,
                      itemBuilder: (context, i) => _row(context, i, cells, key: ValueKey(i)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: 'Add rule · Ctrl+Shift+R',
              child: TertiaryButton(label: 'Add rule', icon: AppIcons.add, onPressed: _add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int i, Widget Function(Widget, Widget, Widget, Widget, Widget) cells, {required Key key}) {
    final c = context.colors;
    final r = rules[i];
    final missing = widget.issues
        .where((x) => x.isError && x.request == r.request && x.storagePath == r.storage && x.suggestedLeaf != null)
        .firstOrNull;
    final dup = widget.issues.any((x) => x.isError && x.request == r.request && x.storagePath == null && r.request.isNotEmpty);
    // Other problems with this rule's paths (placeholders, syntax, filters).
    final pathIssue = missing != null
        ? null
        : widget.issues.where((x) => x.request == r.request && x.storagePath == r.storage && x.detail != null).firstOrNull;
    final mono = context.text.bodyMedium!.mono;
    final resolved = resolveStoragePath(widget.storage, r.storage);
    final mapNode = missing == null && (resolved?.isMap ?? false) && resolved!.children.isNotEmpty ? resolved : null;

    InputDecoration deco({required String label, Widget? error, Widget? helper, String? hint}) => InputDecoration(
      isDense: true,
      hintText: hint,
      helper: helper,
      hintStyle: mono.copyWith(color: c.onSurfaceVariant),
      error: error,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      constraints: const BoxConstraints(minHeight: 40),
      // Matches the row's dropdown buttons: no fill, thin outlineVariant
      // underline at rest, 2px when focused or invalid. These states must be
      // set explicitly: the app's global OutlineInputBorder theme otherwise
      // wins over a plain `border:` for the enabled/focused/error states.
      filled: false,
      border: UnderlineInputBorder(borderSide: BorderSide(color: c.outlineVariant)),
      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.outlineVariant)),
      disabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.outlineVariant)),
      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.primary, width: 2)),
      errorBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.error, width: 2)),
      focusedErrorBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.error, width: 2)),
      semanticCounterText: label,
    );

    final request = Semantics(
      label: 'Request path',
      textField: true,
      child: TextField(
        controller: _req[i],
        focusNode: _reqFocus[i],
        style: mono,
        onChanged: (v) => _set(i, r.copyWith(request: v.trim())),
        decoration: deco(
          label: 'Request path',
          hint: 'request',
          error: dup ? Text('Used by another rule', style: context.text.bodySmall?.copyWith(color: c.error)) : null,
        ),
      ),
    );

    final filterFields = [for (final child in mapNode?.children ?? const <StorageNode>[]) child.key];
    final currentFilters = lastSegmentFilters(r.storage);
    final storage = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _StoragePathField(
                controller: _store[i],
                focusNode: _storeFocus[i],
                root: widget.storage,
                usage: widget.usage,
                decoration:
                    deco(
                      label: 'Storage path for ${r.request}',
                      hint: 'storage.path',
                      error: missing != null
                          ? CodeText(
                              'Error: `${r.storage}` does not exist in storage.',
                              style: context.text.bodySmall?.copyWith(color: c.error),
                            )
                          : pathIssue != null && pathIssue.isError
                          ? CodeText('Error: ${pathIssue.detail}.', style: context.text.bodySmall?.copyWith(color: c.error))
                          : null,
                      helper: pathIssue != null && !pathIssue.isError
                          ? CodeText(
                              'Warning: ${pathIssue.detail}.',
                              style: context.text.bodySmall?.copyWith(color: context.status.warning),
                            )
                          : null,
                    ).copyWith(
                      suffixIcon: missing != null || (pathIssue?.isError ?? false) ? Icon(AppIcons.error, color: c.error, size: 20) : null,
                    ),
                onChanged: (v) {
                  _set(i, r.copyWith(storage: v.trim()));
                  widget.onStoragePathSelected(v.trim());
                },
                onSelectedPath: widget.onStoragePathSelected,
              ),
            ),
            // Field filters only make sense once the path resolves to a map.
            if (mapNode != null)
              IconButton(
                tooltip: 'Filter ${r.storage} by parameter',
                onPressed: () async {
                  final result = await showAssignFiltersDialog(
                    context,
                    parameters: widget.view.parameters,
                    fields: filterFields,
                    filters: currentFilters,
                  );
                  if (result == null) return;
                  _set(i, r.copyWith(storage: withLastSegmentFilters(r.storage, result)));
                },
                icon: const Icon(AppIcons.tune, size: 20),
              ),
          ],
        ),
        if (missing != null)
          TextButton(
            onPressed: () => widget.onQuickFix(r.storage, missing.suggestedLeaf!),
            style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(AppIcons.add, size: 16),
                const SizedBox(width: 6),
                Flexible(child: Text('Add ${r.storage} (${describeLeaf(missing.suggestedLeaf!)}) to storage')),
              ],
            ),
          ),
      ],
    );

    final fields = mapNode == null
        ? const SizedBox.shrink()
        : MenuAnchor(
            menuChildren: [
              MenuItemButton(
                closeOnActivate: false,
                onPressed: () => _set(i, r.copyWith(content: const [])),
                leadingIcon: SizedBox(width: 20, child: r.content.isEmpty ? const Icon(AppIcons.check, size: 20) : null),
                child: const Text('All fields'),
              ),
              const Divider(height: 1),
              for (final child in mapNode.children)
                _fieldMenuItem(
                  node: child,
                  level: r.content,
                  onChanged: (next) => _set(i, r.copyWith(content: next)),
                  mono: context.text.bodyMedium?.mono,
                ),
            ],
            builder: (context, controller, _) => SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.onSurface,
                  side: BorderSide(color: c.outlineVariant),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                  minimumSize: const Size(0, 40),
                ),
                child: Semantics(
                  label: 'Fields exposed for ${r.storage}: ${_contentSummary(r.content)}',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Expanded(child: Text(_contentSummary(r.content), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const Icon(AppIcons.expand, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          );

    final access = MenuAnchor(
      menuChildren: [
        for (final a in RuleAccess.values)
          MenuItemButton(
            onPressed: () => _set(i, r.copyWith(access: a)),
            leadingIcon: SizedBox(width: 20, child: a == r.access ? const Icon(AppIcons.check, size: 20) : null),
            child: Text(a.label),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.onSurface,
          side: BorderSide(color: c.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          minimumSize: const Size(150, 40),
        ),
        child: Semantics(
          label: 'Access for ${r.request}: ${r.access.label}',
          excludeSemantics: true,
          child: Row(
            children: [
              Expanded(child: Text(r.access.label)),
              const Icon(AppIcons.expand, size: 18),
            ],
          ),
        ),
      ),
    );

    final highlight = widget.focusRule == r.request && missing == null;
    final storageSelected = widget.selectedStoragePath != null && ruleExposes(r, widget.selectedStoragePath!);
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(0, 8, 4, 8),
      decoration: BoxDecoration(
        color: missing != null
            ? Color.alphaBlend(c.errorContainer.withValues(alpha: 0.35), c.surfaceContainerLowest)
            : (highlight || storageSelected
                  ? Color.alphaBlend(c.secondaryContainer.withValues(alpha: 0.3), c.surfaceContainerLowest)
                  : null),
        border: Border(top: BorderSide(color: c.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: ReorderableDragStartListener(
              index: i,
              child: Semantics(
                label: 'Reorder rule ${r.request}',
                button: true,
                container: true,
                excludeSemantics: true,
                child: Icon(AppIcons.dragHandle, size: 18, color: c.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: cells(
              request,
              storage,
              fields,
              access,
              IconButton(
                tooltip: 'Delete rule ${r.request} · Ctrl+Backspace',
                onPressed: () => _delete(i),
                icon: const Icon(AppIcons.delete, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short, dot-joined listing of every leaf field a rule's `content` tree
/// exposes (relative to the rule's own storage path), or `'All fields'` when
/// [content] is empty.
String _contentSummary(List<ContentField> content) {
  if (content.isEmpty) return 'All fields';
  Iterable<String> leaves(String prefix, List<ContentField> fields) sync* {
    for (final f in fields) {
      final path = joinTreePath(prefix, f.key);
      if (f.children.isEmpty) {
        yield path;
      } else {
        yield* leaves(path, f.children);
      }
    }
  }

  return leaves('', content).join(', ');
}

/// Whether a storage node can itself be drilled into in the fields menu: a
/// map with fixed keys (recurse into its children), or an array whose
/// elements are such a map (recurse into the element's children, keyed
/// together with the node's own key, e.g. `snaps[{n}]`, matching how a
/// single `content` entry addresses an array's elements).
List<StorageNode> _expandableFieldsOf(StorageNode node) {
  if (node.isMap) return node.children;
  if (node.hasMapElement) return node.element!.children;
  return const [];
}

/// The key a storage node's own entry uses in a `content` tree: its own key
/// for a map field, or that key combined with the array-element marker
/// (`snaps[{n}]`) for an array of maps.
String _contentKeyOf(StorageNode node) => node.hasMapElement ? joinTreePath(node.key, StorageNode.indexKey) : node.key;

/// One row of the recursive "Fields exposed" menu: a plain toggle for a leaf
/// field, or a [SubmenuButton] with its own "All fields" item and nested
/// rows for a map field (or an array of maps) with fixed keys.
///
/// Semantics live entirely in [level], the list this field's own
/// [ContentField] entry (if any) belongs to: an empty [level] means
/// everything at this level is exposed (nothing has been narrowed yet), so
/// picking one field replaces the whole level with just that field; a
/// non-empty [level] is already an explicit subset, so picking toggles that
/// one field's membership without disturbing the rest.
Widget _fieldMenuItem({
  required StorageNode node,
  required List<ContentField> level,
  required void Function(List<ContentField> next) onChanged,
  required TextStyle? mono,
}) {
  final key = _contentKeyOf(node);
  // An array of maps can be fully included two ways in `content`: a plain
  // `storage: snaps` entry (no narrowing), or `storage: snaps[{n}]` with
  // nested `content` (narrowed to a subset of element fields). Both address
  // the same slot, so matching/removal must treat either key as "this
  // field's" entry, or a stale plain entry would linger alongside a newly
  // narrowed one.
  final altKey = node.hasMapElement ? node.key : null;
  bool isThisField(ContentField f) => f.key == key || f.key == altKey;
  final existing = level.where(isThisField).firstOrNull;
  final included = existing != null && existing.children.isEmpty;
  final partial = existing != null && existing.children.isNotEmpty;
  final icon = included
      ? const Icon(AppIcons.check, size: 20)
      : partial
      ? const Icon(AppIcons.dash, size: 20)
      : null;

  List<ContentField> withReplaced(List<ContentField> children) => [
    for (final f in level)
      if (!isThisField(f)) f,
    ContentField(key: key, children: children),
  ];
  List<ContentField> withRemoved() => [
    for (final f in level)
      if (!isThisField(f)) f,
  ];

  void toggleFull() => onChanged(level.isEmpty ? [ContentField(key: key)] : (included ? withRemoved() : withReplaced(const [])));

  final expandable = _expandableFieldsOf(node);
  if (expandable.isEmpty) {
    return MenuItemButton(
      closeOnActivate: false,
      onPressed: toggleFull,
      leadingIcon: SizedBox(width: 20, child: icon),
      child: Text(key, style: mono),
    );
  }
  final childLevel = partial ? existing.children : const <ContentField>[];
  return SubmenuButton(
    leadingIcon: SizedBox(width: 20, child: icon),
    menuChildren: [
      MenuItemButton(
        closeOnActivate: false,
        onPressed: toggleFull,
        leadingIcon: SizedBox(width: 20, child: included ? const Icon(AppIcons.check, size: 20) : null),
        child: const Text('All fields'),
      ),
      const Divider(height: 1),
      for (final grandchild in expandable)
        _fieldMenuItem(node: grandchild, level: childLevel, onChanged: (next) => onChanged(withReplaced(next)), mono: mono),
    ],
    child: Text(key, style: mono),
  );
}

/// Storage path combobox: suggests storage leaves with their type, whether
/// they are ephemeral, and how many views use them.
class _StoragePathField extends StatelessWidget {
  const _StoragePathField({
    required this.controller,
    required this.focusNode,
    required this.root,
    required this.usage,
    required this.decoration,
    required this.onChanged,
    required this.onSelectedPath,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final StorageNode root;
  final Map<String, int> usage;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSelectedPath;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final leaves = [
      ...root.leaves(),
      for (final (_, p, n) in root.walk())
        if (n.isMap && n.children.isNotEmpty) (p, n),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        return RawAutocomplete<(String, StorageNode)>(
          textEditingController: controller,
          focusNode: focusNode,
          displayStringForOption: (o) => o.$1,
          optionsBuilder: (value) {
            final q = value.text.trim();
            if (q.isEmpty) return leaves;
            final query = q.toLowerCase();
            final matches = leaves.where((l) => l.$1.toLowerCase().contains(query) && l.$1 != q).toList();
            matches.sort((a, b) {
              final aPrefix = a.$1.toLowerCase().startsWith(query);
              final bPrefix = b.$1.toLowerCase().startsWith(query);
              return aPrefix == bPrefix ? a.$1.compareTo(b.$1) : (aPrefix ? -1 : 1);
            });
            return matches;
          },
          onSelected: (o) {
            onChanged(o.$1);
            onSelectedPath(o.$1);
          },
          fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
            controller: ctrl,
            focusNode: focus,
            style: context.text.bodyMedium?.mono,
            decoration: decoration,
            onChanged: onChanged,
            onTap: () {
              if (ctrl.text.trim().isNotEmpty) onSelectedPath(ctrl.text.trim());
            },
            onSubmitted: (_) => onSubmit(),
          ),
          optionsViewBuilder: (context, onSelected, options) {
            final list = options.toList();
            final highlighted = AutocompleteHighlightedOption.of(context);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: c.surfaceContainer,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: c.outlineVariant),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 280, maxWidth: constraints.maxWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final (path, node) = list[i];
                            return InkWell(
                              mouseCursor: WidgetStateMouseCursor.clickable,
                              onTap: () => onSelected(list[i]),
                              child: Container(
                                constraints: const BoxConstraints(minHeight: 44),
                                color: i == highlighted ? c.surfaceContainerHighest : null,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        path,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TypeChip(node.typeLabel),
                                    if (node.constraintSummary case final summary?)
                                      Text(summary, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                                    if (node.ephemeral) ...[
                                      const SizedBox(width: 8),
                                      Icon(AppIcons.bolt, size: 14, color: c.onSurfaceVariant),
                                      Text('Ephemeral', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                                    ],
                                    if (node.secret) Text('Secret', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        _usedLabel(path),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.end,
                                        style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: c.outlineVariant)),
                        ),
                        child: Text(
                          controller.text.trim().isEmpty
                              ? plural(leaves.length, 'storage path')
                              : '${list.length} of ${leaves.length} storage paths match “${controller.text.trim()}”',
                          style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _usedLabel(String path) {
    final n = usage[path] ?? 0;
    return n == 0 ? 'No views' : plural(n, 'view');
  }
}
