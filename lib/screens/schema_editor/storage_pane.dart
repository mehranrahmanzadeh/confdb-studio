import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/schema_codec.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/status_badge.dart';
import 'schema_editor_screen.dart';

/// Right pane of the editor: the storage schema as a tree or as JSON.
class StoragePane extends StatelessWidget {
  const StoragePane({
    super.key,
    required this.draft,
    required this.issues,
    required this.focusPath,
    required this.selectedPath,
    required this.onSelectPath,
    required this.searchController,
    required this.searchFocusNode,
    required this.json,
    required this.onJson,
    required this.onStorage,
    required this.onAdd,
    required this.onAddAlias,
    required this.onAddPlaceholder,
    required this.onEdit,
    required this.onDelete,
    required this.onEditAlias,
    required this.onDeleteAlias,
    required this.compact,
  });

  final ConfdbSchema draft;
  final List<LintIssue> issues;
  final String? focusPath;
  final String? selectedPath;
  final ValueChanged<String> onSelectPath;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool json;
  final ValueChanged<bool> onJson;
  final void Function(StorageNode storage, Map<String, StorageNode> aliases) onStorage;

  /// Add a path inside the map at the given path (null: top level).
  final ValueChanged<String?> onAdd;

  /// Create a new top-level alias.
  final VoidCallback onAddAlias;

  /// Gives an empty map a placeholder (any key).
  final ValueChanged<String> onAddPlaceholder;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDelete;
  final ValueChanged<String> onEditAlias;
  final ValueChanged<String> onDeleteAlias;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final unexposed = {
      for (final i in issues)
        if (!i.isError && i.storagePath != null) i.storagePath!,
    };
    final addMenu = MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.add, size: 18),
          onPressed: () => onAdd(null),
          child: const Text('Add storage path'),
        ),
        MenuItemButton(leadingIcon: const Icon(AppIcons.add, size: 18), onPressed: onAddAlias, child: const Text('Create an alias')),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Add storage path or alias',
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(AppIcons.add),
      ),
    );
    final header = Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text('Storage', style: context.text.titleSmall)),
        ),
        if (!json) addMenu,
        const SizedBox(width: 4),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Tree')),
            ButtonSegment(value: true, label: Text('JSON')),
          ],
          selected: {json},
          onSelectionChanged: (s) => onJson(s.first),
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
      ],
    );
    final body = json
        ? _JsonEditor(storage: draft.storage, aliases: draft.aliases, warnPaths: unexposed, onChanged: onStorage, expand: !compact)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (draft.aliases.isNotEmpty) ...[
                _AliasesSection(aliases: draft.aliases, onEdit: onEditAlias, onDelete: onDeleteAlias),
                const SizedBox(height: 8),
              ],
              _Tree(
                draft: draft,
                unexposed: unexposed,
                focusPath: focusPath,
                selectedPath: selectedPath,
                onSelectPath: onSelectPath,
                searchController: searchController,
                searchFocusNode: searchFocusNode,
                onAdd: onAdd,
                onAddPlaceholder: onAddPlaceholder,
                onEdit: onEdit,
                onDelete: onDelete,
              ),
            ],
          );
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: compact ? Border(top: BorderSide(color: c.outlineVariant)) : null,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 12),
          if (compact || json) (compact ? body : Expanded(child: body)) else Expanded(child: SingleChildScrollView(child: body)),
        ],
      ),
    );
  }
}

/// Lists top-level aliases (reusable types), each with its definition and
/// edit/delete actions.
class _AliasesSection extends StatelessWidget {
  const _AliasesSection({required this.aliases, required this.onEdit, required this.onDelete});
  final Map<String, StorageNode> aliases;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Aliases', style: context.text.labelLarge)),
          const SizedBox(height: 4),
          for (final e in aliases.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(e.key, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
                            TypeChip(e.value.typeLabel),
                          ],
                        ),
                        if (e.value.constraintSummary case final summary?)
                          Text(
                            summary,
                            style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  MenuAnchor(
                    menuChildren: [
                      MenuItemButton(
                        leadingIcon: const Icon(AppIcons.edit, size: 18),
                        onPressed: () => onEdit(e.key),
                        child: const Text('Edit'),
                      ),
                      MenuItemButton(
                        leadingIcon: const Icon(AppIcons.delete, size: 18),
                        onPressed: () => onDelete(e.key),
                        child: const Text('Delete'),
                      ),
                    ],
                    builder: (context, controller, _) => IconButton(
                      tooltip: 'Actions for alias ${e.key}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                      icon: const Icon(Icons.more_vert, size: 18),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Tree extends StatefulWidget {
  const _Tree({
    required this.draft,
    required this.unexposed,
    required this.focusPath,
    required this.selectedPath,
    required this.onSelectPath,
    required this.searchController,
    required this.searchFocusNode,
    required this.onAdd,
    required this.onAddPlaceholder,
    required this.onEdit,
    required this.onDelete,
  });
  final ConfdbSchema draft;
  final Set<String> unexposed;
  final String? focusPath;
  final String? selectedPath;
  final ValueChanged<String> onSelectPath;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ValueChanged<String?> onAdd;

  /// Gives an empty map a placeholder (any key).
  final ValueChanged<String> onAddPlaceholder;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDelete;

  @override
  State<_Tree> createState() => _TreeState();
}

/// Whether [path] is inside a collapsed ancestor, i.e. [ancestor] is a
/// strict, segment-aligned prefix of it (`a.b` or `a[{n}]`, not `a.bc`).
bool _isDescendant(String path, String ancestor) =>
    path.length > ancestor.length && path.startsWith(ancestor) && (path[ancestor.length] == '.' || path[ancestor.length] == '[');

class _TreeState extends State<_Tree> {
  final _collapsed = <String>{};
  String _query = '';

  @override
  void didUpdateWidget(_Tree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focusPath = widget.focusPath;
    if (focusPath != null && focusPath != oldWidget.focusPath) {
      _collapsed.removeWhere((path) => _isDescendant(focusPath, path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final unexposed = widget.unexposed;
    final focusPath = widget.focusPath;
    final selectedPath = widget.selectedPath;
    final onSelectPath = widget.onSelectPath;
    final onAdd = widget.onAdd;
    final onAddPlaceholder = widget.onAddPlaceholder;
    final onEdit = widget.onEdit;
    final onDelete = widget.onDelete;
    final c = context.colors;
    final s = context.status;
    final usage = storageUsage(draft);
    final rows = <Widget>[];
    final allRows = draft.storage.walk().toList();
    final matches = allRows.where((row) => row.$2.toLowerCase().contains(_query.toLowerCase())).toList();
    final visiblePaths = <String>{};
    for (final (_, path, _) in matches) {
      var prefix = path;
      visiblePaths.add(prefix);
      while (true) {
        final dot = prefix.lastIndexOf('.');
        final bracket = prefix.lastIndexOf('[');
        final boundary = dot > bracket ? dot : bracket;
        if (boundary <= 0) break;
        prefix = prefix.substring(0, boundary);
        visiblePaths.add(prefix);
      }
    }
    for (final (depth, path, node) in allRows) {
      if (_query.isNotEmpty && !visiblePaths.contains(path)) continue;
      if (_query.isEmpty && _collapsed.any((p) => _isDescendant(path, p))) continue;
      final warn = unexposed.contains(path);
      final focused = path == focusPath;
      final selected = path == selectedPath;
      final isNew = draft.addedInDraft.contains(path);
      int used;
      if (node.isMap) {
        used = draft.views.where((v) => v.rules.any((r) => ruleExposes(r, path))).length;
      } else {
        used = usage[path] ?? 0;
      }
      final users = draft.viewsUsing(path);
      final writeOnly = users.isNotEmpty && users.every((u) => !u.$2.access.canRead);
      final placeholder = path.split('.').last == StorageNode.placeholderKey;
      final keysNode = placeholder ? draft.storage.lookup(path.substring(0, path.lastIndexOf('.')))?.keys : null;
      final arrayElement = splitTreePath(path).last == StorageNode.indexKey;
      final sub = [
        if (placeholder)
          keysNode?.aliasRef != null
              ? 'keys match alias `${keysNode!.aliasRef}`'
              : keysNode?.pattern == null
              ? 'any <placeholder>'
              : 'keys match ${keysNode!.pattern}',
        if (arrayElement) 'one per array element',
        if (warn) 'Warning: not exposed by any view',
        if (writeOnly) 'write-only through ${users.map((u) => u.$1.name).toSet().join(', ')}',
        if (node.isEnum) node.choices.join(' | ') else ?node.constraintSummary,
        if (node.ephemeral && !node.isMap) 'loaded by load-view hook',
        if (node.required.isNotEmpty) 'requires ${node.required.map((c) => c.join(' & ')).join(' or ')}',
        if (isNew) 'added in draft',
      ];
      final menu = MenuAnchor(
        menuChildren: [
          // An array's element definition is edited/removed through the array
          // itself; only adding fields inside it applies here.
          if (!arrayElement) ...[
            MenuItemButton(leadingIcon: const Icon(AppIcons.edit, size: 18), onPressed: () => onEdit(path), child: const Text('Edit')),
          ],
          if (node.isMap && !node.hasPlaceholder)
            MenuItemButton(leadingIcon: const Icon(AppIcons.add, size: 18), onPressed: () => onAdd(path), child: const Text('Add child')),
          // snapd maps have fixed keys ("schema") or a placeholder ("values"), not both.
          if (node.isMap && !node.hasPlaceholder)
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.placeholder, size: 18),
              onPressed: node.children.isEmpty ? () => onAddPlaceholder(path) : null,
              child: Text(node.children.isEmpty ? 'Add placeholder' : 'Add placeholder (map must be empty)'),
            ),
          if (!arrayElement)
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.delete, size: 18),
              onPressed: () => onDelete(path),
              child: const Text('Delete'),
            ),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: 'Actions for $path',
          visualDensity: VisualDensity.compact,
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.more_vert, size: 18),
        ),
      );
      // Expandable nodes toggle their children when tapped anywhere on the row;
      // editing them is still reachable via the "..." menu. Non-expandable nodes
      // (leaves and empty maps) open the edit dialog on tap instead, since there's
      // nothing to collapse.
      final expandable = node.isMap && node.children.isNotEmpty;
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                mouseCursor: arrayElement ? MouseCursor.defer : WidgetStateMouseCursor.clickable,
                borderRadius: BorderRadius.circular(8),
                onTap: arrayElement
                    ? null
                    : () {
                        onSelectPath(path);
                        if (expandable) {
                          setState(() {
                            if (!_collapsed.add(path)) _collapsed.remove(path);
                          });
                        } else {
                          onEdit(path);
                        }
                      },
                child: Semantics(
                  button: !arrayElement,
                  label: arrayElement
                      ? 'Array elements: ${node.typeLabel}'
                      : expandable
                      ? '${_collapsed.contains(path) ? 'Expand' : 'Collapse'} ${node.displayKey}'
                      : 'Edit ${node.displayKey}: ${node.typeLabel}, ${used == 0 ? 'no views' : plural(used, 'view')}${warn ? ', not exposed' : ''}',
                  child: Container(
                    padding: EdgeInsets.fromLTRB(8 + depth * 20.0, 6, 8, 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: selected || focused
                          ? Color.alphaBlend(c.secondaryContainer.withValues(alpha: 0.5), c.surfaceContainerLow)
                          : warn
                          ? Color.alphaBlend(s.warningContainer.withValues(alpha: 0.45), c.surfaceContainerLow)
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Opacity(
                              opacity: node.isMap ? 1 : 0,
                              child: expandable
                                  ? Semantics(
                                      button: true,
                                      label: '${_collapsed.contains(path) ? 'Expand' : 'Collapse'} ${node.displayKey}',
                                      excludeSemantics: true,
                                      child: Icon(
                                        _collapsed.contains(path) ? AppIcons.chevronRight : AppIcons.expand,
                                        size: 16,
                                        color: c.onSurfaceVariant,
                                      ),
                                    )
                                  : Icon(AppIcons.expand, size: 16, color: c.onSurfaceVariant),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (placeholder || arrayElement) Icon(AppIcons.placeholder, size: 16, color: c.onSurfaceVariant),
                                  Text(node.displayKey, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
                                  TypeChip(node.typeLabel),
                                  if (node.secret) const SecretChip(),
                                  if (isNew) const StatusBadge.info('New', icon: AppIcons.add),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (warn) ...[Icon(AppIcons.warning, size: 14, color: s.warning), const SizedBox(width: 4)],
                            Text(
                              used == 0 ? 'No views' : plural(used, 'view'),
                              style: context.text.bodySmall?.copyWith(color: warn ? s.warning : c.onSurfaceVariant),
                            ),
                          ],
                        ),
                        if (sub.isNotEmpty || (node.ephemeral && !node.isMap))
                          Padding(
                            padding: const EdgeInsets.only(left: 24, top: 2),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (node.ephemeral && !node.isMap) const EphemeralChip(),
                                Text(
                                  sub.join(' · '),
                                  style: context.text.bodySmall?.copyWith(color: warn ? s.warning : c.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            menu,
          ],
        ),
      );
      rows.add(const SizedBox(height: 2));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: widget.searchController,
            focusNode: widget.searchFocusNode,
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search storage paths',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        widget.searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close, size: 16),
                    ),
              helperText: _query.isEmpty ? 'Ctrl+F to focus' : '${matches.length} matching ${matches.length == 1 ? 'path' : 'paths'}',
            ),
          ),
        ),
        if (rows.isEmpty && _query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No storage paths match “$_query”.', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          )
        else
          ...rows,
      ],
    );
  }
}

/// Highlights JSON keys (tertiary) and marks lines with lint warnings.
class _JsonController extends TextEditingController {
  _JsonController(String text) : super(text: text);

  Set<int> warnLines = const {};
  // Set from the theme on every build.
  Color keyColor = Colors.transparent;
  Color punctuation = Colors.transparent;
  Color warnBackground = Colors.transparent;

  static final _key = RegExp(r'^(\s*)("[^"]*")(\s*:\s*)(.*)$');

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final lines = text.split('\n');
    final spans = <TextSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final bg = warnLines.contains(i) ? warnBackground : null;
      final m = _key.firstMatch(lines[i]);
      if (m == null) {
        spans.add(
          TextSpan(
            text: lines[i],
            style: TextStyle(backgroundColor: bg),
          ),
        );
      } else {
        spans.addAll([
          TextSpan(
            text: m[1],
            style: TextStyle(backgroundColor: bg),
          ),
          TextSpan(
            text: m[2],
            style: TextStyle(color: keyColor, backgroundColor: bg),
          ),
          TextSpan(
            text: m[3],
            style: TextStyle(color: punctuation, backgroundColor: bg),
          ),
          TextSpan(
            text: m[4],
            style: TextStyle(backgroundColor: bg),
          ),
        ]);
      }
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: style, children: spans);
  }
}

class _JsonEditor extends StatefulWidget {
  const _JsonEditor({required this.storage, required this.aliases, required this.warnPaths, required this.onChanged, required this.expand});
  final StorageNode storage;
  final Map<String, StorageNode> aliases;
  final Set<String> warnPaths;
  final void Function(StorageNode storage, Map<String, StorageNode> aliases) onChanged;
  final bool expand;

  @override
  State<_JsonEditor> createState() => _JsonEditorState();
}

class _JsonEditorState extends State<_JsonEditor> {
  late final _ctrl = _JsonController(prettyStorageJson(widget.storage, aliases: widget.aliases));
  final _focus = FocusNode();
  String? _error;
  StorageNode? _lastEmitted;

  @override
  void didUpdateWidget(_JsonEditor old) {
    super.didUpdateWidget(old);
    // Storage changed elsewhere (quick fix): refresh unless the user is typing here.
    if (!identical(widget.storage, _lastEmitted) && !_focus.hasFocus && _error == null) {
      final next = prettyStorageJson(widget.storage, aliases: widget.aliases);
      if (next != _ctrl.text) _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    try {
      final decoded = decodeStorage(jsonDecode(text));
      setState(() => _error = null);
      _lastEmitted = decoded.storage;
      widget.onChanged(decoded.storage, decoded.aliases);
    } on FormatException catch (e) {
      setState(() => _error = 'Invalid JSON: ${e.message}');
    } on SchemaFormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  /// Line index of each warned path, found by walking its segments in order.
  Set<int> _warnLines(List<String> lines) {
    final out = <int>{};
    for (final path in widget.warnPaths) {
      var from = 0;
      int? at;
      for (final seg in path.split('.')) {
        at = null;
        for (var i = from; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('"$seg"')) {
            at = i;
            from = i + 1;
            break;
          }
        }
        if (at == null) break;
      }
      if (at != null) out.add(at);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final lines = _ctrl.text.split('\n');
    final warn = _warnLines(lines);
    _ctrl
      ..warnLines = warn
      ..keyColor = c.tertiary
      ..punctuation = c.onSurfaceVariant
      ..warnBackground = Color.alphaBlend(s.warningContainer.withValues(alpha: 0.55), c.surfaceContainerLowest);
    final style = context.text.bodySmall!.mono.copyWith(height: 20 / 12, color: c.onSurface);
    const strut = StrutStyle(fontSize: 12, height: 20 / 12, forceStrutHeight: true);

    final editor = SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: SizedBox(
              width: 40,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < lines.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        '${i + 1}',
                        style: style.copyWith(color: c.onSurfaceVariant),
                        strutStyle: strut,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 640,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  maxLines: null,
                  style: style,
                  strutStyle: strut,
                  onChanged: _onChanged,
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.only(right: 12),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final footerText =
        _error ??
        'Valid JSON · matches the confdb storage format'
            '${warn.isEmpty ? '' : ' · ${warn.length == 1 ? 'line ${warn.first + 1} has' : 'lines ${(warn.toList()..sort()).map((l) => l + 1).join(', ')} have'} a lint warning'}';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surfaceContainerLowest,
        border: Border.all(color: _error == null ? c.outlineVariant : c.error, width: _error == null ? 1 : 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.outlineVariant)),
            ),
            child: Text('storage schema · JSON', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ),
          if (widget.expand) Expanded(child: editor) else SizedBox(height: 520, child: editor),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.outlineVariant)),
              ),
              child: Row(
                children: [
                  Icon(_error == null ? AppIcons.ok : AppIcons.error, size: 14, color: _error == null ? s.success : c.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(footerText, style: context.text.bodySmall?.copyWith(color: _error == null ? c.onSurfaceVariant : c.error)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
