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
    required this.json,
    required this.onJson,
    required this.onStorage,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.compact,
  });

  final ConfdbSchema draft;
  final List<LintIssue> issues;
  final String? focusPath;
  final bool json;
  final ValueChanged<bool> onJson;
  final ValueChanged<StorageNode> onStorage;

  /// Add a path inside the map at the given path (null: top level).
  final ValueChanged<String?> onAdd;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDelete;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final unexposed = {
      for (final i in issues)
        if (!i.isError && i.storagePath != null) i.storagePath!,
    };
    final header = Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text('Storage', style: context.text.titleSmall)),
        ),
        if (!json) IconButton(tooltip: 'Add storage path', onPressed: () => onAdd(null), icon: const Icon(AppIcons.add)),
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
        ? _JsonEditor(storage: draft.storage, warnPaths: unexposed, onChanged: onStorage, expand: !compact)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_Tree(draft: draft, unexposed: unexposed, focusPath: focusPath, onAdd: onAdd, onEdit: onEdit, onDelete: onDelete)],
          );
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
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

class _Tree extends StatelessWidget {
  const _Tree({
    required this.draft,
    required this.unexposed,
    required this.focusPath,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });
  final ConfdbSchema draft;
  final Set<String> unexposed;
  final String? focusPath;
  final ValueChanged<String?> onAdd;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final usage = storageUsage(draft);
    final rows = <Widget>[];
    for (final (depth, path, node) in draft.storage.walk()) {
      final warn = unexposed.contains(path);
      final focused = path == focusPath;
      final isNew = draft.addedInDraft.contains(path);
      int used;
      if (node.isMap) {
        used = draft.views.where((v) => v.rules.any((r) => ruleCovers(path, r.storage) || ruleCovers(r.storage, path))).length;
      } else {
        used = usage[path] ?? 0;
      }
      final users = draft.viewsUsing(path);
      final writeOnly = users.isNotEmpty && users.every((u) => !u.$2.access.canRead);
      final sub = [
        if (warn) 'Warning: not exposed by any view',
        if (writeOnly) 'write-only through ${users.map((u) => u.$1.name).toSet().join(', ')}',
        if (node.isEnum) node.choices.join(' | ') else ?node.constraintSummary,
        if (node.ephemeral && !node.isMap) 'loaded by load-view hook',
        if (isNew) 'added in draft',
      ];
      final menu = MenuAnchor(
        menuChildren: [
          MenuItemButton(leadingIcon: const Icon(AppIcons.edit, size: 18), onPressed: () => onEdit(path), child: const Text('Edit')),
          if (node.isMap && node.valuesType == null)
            MenuItemButton(leadingIcon: const Icon(AppIcons.add, size: 18), onPressed: () => onAdd(path), child: const Text('Add child')),
          MenuItemButton(leadingIcon: const Icon(AppIcons.delete, size: 18), onPressed: () => onDelete(path), child: const Text('Delete')),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: 'Actions for $path',
          visualDensity: VisualDensity.compact,
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.more_vert, size: 18),
        ),
      );
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                mouseCursor: WidgetStateMouseCursor.clickable,
                borderRadius: BorderRadius.circular(8),
                onTap: () => onEdit(path),
                child: Semantics(
                  button: true,
                  label:
                      'Edit ${node.key}: ${node.typeLabel}, ${used == 0 ? 'no views' : plural(used, 'view')}${warn ? ', not exposed' : ''}',
                  excludeSemantics: true,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(8 + depth * 20.0, 6, 8, 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: focused
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
                              child: Icon(AppIcons.expand, size: 16, color: c.onSurfaceVariant),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(node.key, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
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
  const _JsonEditor({required this.storage, required this.warnPaths, required this.onChanged, required this.expand});
  final StorageNode storage;
  final Set<String> warnPaths;
  final ValueChanged<StorageNode> onChanged;
  final bool expand;

  @override
  State<_JsonEditor> createState() => _JsonEditorState();
}

class _JsonEditorState extends State<_JsonEditor> {
  late final _ctrl = _JsonController(prettyStorageJson(widget.storage));
  final _focus = FocusNode();
  String? _error;
  StorageNode? _lastEmitted;

  @override
  void didUpdateWidget(_JsonEditor old) {
    super.didUpdateWidget(old);
    // Storage changed elsewhere (quick fix): refresh unless the user is typing here.
    if (!identical(widget.storage, _lastEmitted) && !_focus.hasFocus && _error == null) {
      final next = prettyStorageJson(widget.storage);
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
      final root = decodeStorage(jsonDecode(text));
      setState(() => _error = null);
      _lastEmitted = root;
      widget.onChanged(root);
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
