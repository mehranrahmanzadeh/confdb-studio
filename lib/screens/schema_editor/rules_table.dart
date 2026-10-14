import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';

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

  void _set(int i, ViewRule rule) => widget.onChanged([for (var j = 0; j < rules.length; j++) j == i ? rule : rules[j]]);

  void _delete(int i) => widget.onChanged([
    for (var j = 0; j < rules.length; j++)
      if (j != i) rules[j],
  ]);

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
    Widget cells(Widget a, Widget b, Widget d, Widget e) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 8, child: a),
        const SizedBox(width: 12),
        Expanded(flex: 16, child: b),
        const SizedBox(width: 12),
        SizedBox(width: 150, child: d),
        const SizedBox(width: 12),
        SizedBox(width: 40, child: e),
      ],
    );

    return Column(
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                  alignment: Alignment.centerLeft,
                  child: cells(
                    Text('Request path', style: head),
                    Text('Storage path', style: head),
                    Text('Access', style: head),
                    Semantics(label: 'Actions', child: const SizedBox.shrink()),
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
                  ),
                for (var i = 0; i < rules.length; i++) _row(context, i, cells),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TertiaryButton(label: 'Add rule', icon: AppIcons.add, onPressed: _add),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int i, Widget Function(Widget, Widget, Widget, Widget) cells) {
    final c = context.colors;
    final r = rules[i];
    final missing = widget.issues
        .where((x) => x.isError && x.request == r.request && x.storagePath == r.storage && x.suggestedLeaf != null)
        .firstOrNull;
    final dup = widget.issues.any((x) => x.isError && x.request == r.request && x.storagePath == null && r.request.isNotEmpty);
    final mono = context.text.bodyMedium!.mono;

    InputDecoration deco({required String label, Widget? error, String? hint}) => InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: mono.copyWith(color: c.onSurfaceVariant),
      error: error,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      // Looks editable at rest: filled, thin border; stronger on hover, 2px when focused or invalid.
      filled: true,
      fillColor: c.surfaceContainer,
      hoverColor: c.surfaceContainerHigh,
      border: WidgetStateInputBorder.resolveWith((states) {
        final side = states.contains(WidgetState.error)
            ? BorderSide(color: c.error, width: 2)
            : states.contains(WidgetState.focused)
            ? BorderSide(color: c.primary, width: 2)
            : states.contains(WidgetState.hovered)
            ? BorderSide(color: c.outline)
            : BorderSide(color: c.outlineVariant);
        return OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: side);
      }),
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

    final storage = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StoragePathField(
          controller: _store[i],
          focusNode: _storeFocus[i],
          root: widget.storage,
          usage: widget.usage,
          decoration: deco(
            label: 'Storage path for ${r.request}',
            hint: 'storage.path',
            error: missing == null
                ? null
                : CodeText('Error: `${r.storage}` does not exist in storage.', style: context.text.bodySmall?.copyWith(color: c.error)),
          ).copyWith(suffixIcon: missing == null ? null : Icon(AppIcons.error, color: c.error, size: 20)),
          onChanged: (v) => _set(i, r.copyWith(storage: v.trim())),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      decoration: BoxDecoration(
        color: missing != null
            ? Color.alphaBlend(c.errorContainer.withValues(alpha: 0.35), c.surfaceContainerLowest)
            : (highlight ? Color.alphaBlend(c.secondaryContainer.withValues(alpha: 0.3), c.surfaceContainerLowest) : null),
        border: Border(top: BorderSide(color: c.outlineVariant)),
      ),
      child: cells(
        request,
        storage,
        access,
        IconButton(tooltip: 'Delete rule ${r.request}', onPressed: () => _delete(i), icon: const Icon(AppIcons.delete, size: 20)),
      ),
    );
  }
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
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final StorageNode root;
  final Map<String, int> usage;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final leaves = root.leaves().toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        return RawAutocomplete<(String, StorageNode)>(
          textEditingController: controller,
          focusNode: focusNode,
          displayStringForOption: (o) => o.$1,
          optionsBuilder: (value) {
            final q = value.text.trim();
            if (q.isEmpty) return leaves;
            return leaves.where((l) => l.$1.contains(q) && l.$1 != q);
          },
          onSelected: (o) => onChanged(o.$1),
          fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
            controller: ctrl,
            focusNode: focus,
            style: context.text.bodyMedium?.mono,
            decoration: decoration,
            onChanged: onChanged,
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
                              onTap: () => onSelected(list[i]),
                              child: Container(
                                constraints: const BoxConstraints(minHeight: 44),
                                color: i == highlighted ? c.surfaceContainerHighest : null,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Row(
                                  children: [
                                    Text(path, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
                                    const SizedBox(width: 8),
                                    TypeChip(node.typeLabel),
                                    if (node.ephemeral) ...[
                                      const SizedBox(width: 8),
                                      Icon(AppIcons.bolt, size: 14, color: c.onSurfaceVariant),
                                      Text('Ephemeral', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                                    ],
                                    const Spacer(),
                                    Text(_usedLabel(path), style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
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
