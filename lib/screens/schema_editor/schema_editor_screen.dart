import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/storage_edit.dart';
import '../../shell/app_shell.dart';
import '../../shell/screen_host.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/copyable_text.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/loader.dart';
import '../../widgets/resize_handle.dart';
import '../../widgets/status_badge.dart';
import '../playground/playground_screen.dart';
import 'rules_table.dart';
import 'storage_node_dialog.dart';
import 'storage_pane.dart';
import 'views_pane.dart';

/// How many views map each storage leaf.
Map<String, int> storageUsage(ConfdbSchema s) => {
  for (final (path, _) in s.storage.leaves())
    path: s.views.where((v) => v.rules.any((r) => ruleCovers(r.storage, path) || ruleCovers(path, r.storage))).length,
};

class _EditorData {
  const _EditorData(this.schemas, this.drafts, this.snaps);
  final List<ConfdbSchema> schemas;
  final List<ConfdbSchema> drafts;
  final List<SnapInfo> snaps;
}

Future<_EditorData> _load(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listDrafts(), repo.listSnaps()]);
  return _EditorData(r[0] as List<ConfdbSchema>, r[1] as List<ConfdbSchema>, r[2] as List<SnapInfo>);
}

/// 7.4 Schema editor (SchemaEditor.dc.html, -JSON, -Fixed), and on a
/// [PlaygroundRoute] its playground step, under the same header.
class SchemaEditorScreen extends StatelessWidget {
  const SchemaEditorScreen({super.key, required this.route});
  final AuthoringRoute route;

  @override
  Widget build(BuildContext context) => Loader<_EditorData>(
    key: ValueKey(route.id),
    load: _load,
    reloadOnChange: false,
    loading: (context) => const _EditorSkeleton(),
    error: (context, e, retry) => Padding(
      padding: const EdgeInsets.all(24),
      child: LoadErrorMessage(title: 'Couldn’t open ${route.id.path}', error: e, onRetry: retry),
    ),
    builder: (context, data, _) {
      final base = data.schemas.where((s) => s.id == route.id).firstOrNull;
      final draft = data.drafts.where((s) => s.id == route.id).firstOrNull;
      if (base == null && draft == null) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: EmptyState(
            icon: AppIcons.schemas,
            title: 'No schema ${route.id.path}',
            body: const Text('It isn’t acknowledged on this device and there is no local draft.'),
            actions: [SecondaryButton(label: 'All schemas', onPressed: () => context.app.go(const OverviewRoute()))],
          ),
        );
      }
      if (base?.builtIn ?? false) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: InlineMessage(
            kind: MessageKind.info,
            title: '${route.id.path} is built into snapd',
            body: const Text('Built-in schemas are read-only. Browse their values in the Data explorer.'),
          ),
        );
      }
      return _Editor(
        route: route,
        base: base,
        snaps: data.snaps,
        initial: draft ?? base!.copyWith(isDraft: true, baseRevision: base.revision),
      );
    },
  );
}

class _Editor extends StatefulWidget {
  const _Editor({required this.route, required this.base, required this.snaps, required this.initial});
  final AuthoringRoute route;

  /// Installed snaps, to name the plugs a deleted view leaves behind.
  final List<SnapInfo> snaps;

  /// The acknowledged revision, if any.
  final ConfdbSchema? base;
  final ConfdbSchema initial;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late ConfdbSchema _draft = widget.initial;
  late String? _view = widget.route.view ?? widget.initial.views.firstOrNull?.name;
  late String? _focusPath = _editRoute?.focusStoragePath;
  String? _focusRule;
  bool _json = false;
  Timer? _save;

  SchemaId get id => _draft.id;

  SchemaEditorRoute? get _editRoute => switch (widget.route) {
    final SchemaEditorRoute r => r,
    PlaygroundRoute() => null,
  };

  PlaygroundRoute? get _playRoute => switch (widget.route) {
    final PlaygroundRoute r => r,
    SchemaEditorRoute() => null,
  };

  @override
  void initState() {
    super.initState();
    if (widget.route.view == null && _view != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.app.replace(SchemaEditorRoute(id, view: _view, focusStoragePath: _focusPath));
      });
    }
  }

  @override
  void didUpdateWidget(_Editor old) {
    super.didUpdateWidget(old);
    final r = widget.route;
    if (r.view != null && r.view != _view) _view = r.view;
    if (r is SchemaEditorRoute &&
        old.route is SchemaEditorRoute &&
        r.focusStoragePath != (old.route as SchemaEditorRoute).focusStoragePath) {
      _focusPath = r.focusStoragePath;
    }
  }

  @override
  void dispose() {
    if (_save?.isActive ?? false) {
      _save!.cancel();
      context.repo.saveDraft(_draft);
    }
    super.dispose();
  }

  void _update(ConfdbSchema next) {
    setState(() => _draft = next);
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () => context.repo.saveDraft(_draft));
  }

  Future<void> _flush() async {
    _save?.cancel();
    await context.repo.saveDraft(_draft);
  }

  void _selectView(String name, {String? rule}) {
    setState(() {
      _view = name;
      _focusRule = rule;
    });
    context.app.replace(SchemaEditorRoute(id, view: name));
  }

  void _setRules(List<ViewRule> rules) {
    _update(_draft.copyWith(views: [for (final v in _draft.views) v.name == _view ? v.copyWith(rules: rules) : v]));
  }

  void _addView(String name) {
    _update(
      _draft.copyWith(
        views: [
          ..._draft.views,
          ViewDef(name: name, rules: const []),
        ],
      ),
    );
    _selectView(name);
  }

  Future<void> _deleteView(ViewDef v) async {
    final ref = id.view(v.name);
    final plugs = [
      for (final s in widget.snaps)
        for (final p in s.plugs)
          if (p.view == ref) p,
    ];
    final acknowledged = widget.base?.view(v.name) != null;
    final ok = await confirmDestructive(
      context,
      title: CodeText('Delete view `${v.name}`?'),
      action: 'Delete view',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            acknowledged
                ? 'It’s removed from the draft with its ${plural(v.rules.length, 'rule')}. The device keeps serving it until you sign and acknowledge the next revision. Stored values stay in storage.'
                : 'It’s removed from the draft with its ${plural(v.rules.length, 'rule')}.',
          ),
          if (acknowledged && plugs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('After that, these plugs can no longer read or write through it:'),
            const SizedBox(height: 4),
            for (final p in plugs) Text('${p.id} · ${p.role.name}', style: context.text.bodyMedium?.mono),
          ],
        ],
      ),
    );
    if (!ok || !mounted) return;
    final rest = [
      for (final x in _draft.views)
        if (x.name != v.name) x,
    ];
    _update(_draft.copyWith(views: rest));
    final next = rest.firstOrNull?.name;
    setState(() {
      _view = next;
      _focusRule = null;
    });
    context.app.replace(SchemaEditorRoute(id, view: next));
  }

  void _quickFix(String path, StorageNode leaf) {
    _update(_draft.copyWith(storage: _draft.storage.insert(path, leaf), addedInDraft: {..._draft.addedInDraft, path}));
    setState(() => _focusPath = path);
  }

  Future<void> _addNode(String? parent) async {
    final edit = await showStorageNodeDialog(context, draft: _draft, parent: parent, snapdVersion: context.app.status?.snapdVersion);
    if (edit == null || !mounted) return;
    _update(_draft.copyWith(storage: _draft.storage.insert(edit.path, edit.node), addedInDraft: {..._draft.addedInDraft, edit.path}));
    setState(() => _focusPath = edit.path);
  }

  /// Gives the empty map at [mapPath] a placeholder: any key, typed values.
  Future<void> _addPlaceholder(String mapPath) async {
    final edit = await showStorageNodeDialog(
      context,
      draft: _draft,
      placeholderOf: mapPath,
      snapdVersion: context.app.status?.snapdVersion,
    );
    if (edit == null || !mounted) return;
    _setPlaceholder(mapPath, edit);
    setState(() => _focusPath = edit.path);
  }

  void _setPlaceholder(String mapPath, StorageEdit edit) {
    final map = _draft.storage.lookup(mapPath)!.withElement(edit.node).withKeys(edit.keys);
    _update(
      _draft.copyWith(
        storage: replaceAt(_draft.storage, mapPath, map),
        addedInDraft: {
          // Keys under a placeholder that stopped being a map go with it.
          for (final p in _draft.addedInDraft)
            if (edit.node.isMap || !p.startsWith('${edit.path}.')) p,
          if (_draft.storage.lookup(edit.path) == null) edit.path,
        },
      ),
    );
  }

  Future<void> _editNode(String path) async {
    final edit = await showStorageNodeDialog(context, draft: _draft, path: path, snapdVersion: context.app.status?.snapdVersion);
    if (edit == null || !mounted) return;
    if (edit.placeholder) {
      _setPlaceholder(edit.parent!, edit);
      setState(() => _focusPath = edit.path);
      return;
    }
    var views = _draft.views;
    var added = _draft.addedInDraft;
    // A map that became a leaf loses its children.
    if (!edit.node.isMap) {
      added = {
        for (final p in added)
          if (!p.startsWith('$path.')) p,
      };
    }
    if (edit.path != path) {
      views = renameStorage(views, path, edit.path);
      added = renamePaths(added, path, edit.path);
    }
    _update(_draft.copyWith(storage: replaceAt(_draft.storage, path, edit.node), views: views, addedInDraft: added));
    setState(() => _focusPath = edit.path);
  }

  Future<void> _deleteNode(String path) async {
    final users = [
      for (final v in _draft.views)
        for (final r in v.rules)
          if (ruleCovers(path, r.storage) || ruleCovers(r.storage, path)) '${v.name} › ${r.request}',
    ];
    if (users.isNotEmpty) {
      final ok = await confirmDestructive(
        context,
        title: CodeText('Delete `$path`?'),
        action: 'Delete path',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${plural(users.length, 'rule')} still map to it and will show lint errors until you change or remove them:'),
            const SizedBox(height: 8),
            for (final u in users) Text(u, style: context.text.bodyMedium?.mono),
          ],
        ),
      );
      if (!ok || !mounted) return;
    }
    _update(
      _draft.copyWith(
        storage: removeAt(_draft.storage, path),
        addedInDraft: {
          for (final p in _draft.addedInDraft)
            if (p != path && !p.startsWith('$path.')) p,
        },
      ),
    );
  }

  Future<void> _openPlayground() async {
    final app = context.app;
    await _flush();
    if (_view != null) app.go(PlaygroundRoute(id, view: _view!));
  }

  void _backToEditor() => context.app.go(SchemaEditorRoute(id, view: _view, focusStoragePath: _focusPath));

  void _showInStorage(String path) => setState(() {
    _focusPath = path;
    _json = false;
  });

  static const _minSide = 200.0, _maxViews = 480.0, _minStorage = 280.0, _maxStorage = 760.0, _minCenter = 380.0;

  /// Views | rules | storage, with draggable dividers. The middle column
  /// keeps at least [_minCenter]; side panes stay within their limits.
  Widget _resizableRow(double total, Widget views, Widget center, Widget storage) {
    final app = context.app;
    final room = total - 2 * ResizeHandle.width - _minCenter;
    double clampViews(double w, double right) => w.clamp(_minSide, (room - right).clamp(_minSide, _maxViews));
    double clampStorage(double w, double left) => w.clamp(_minStorage, (room - left).clamp(_minStorage, _maxStorage));
    var right = clampStorage(_json ? app.jsonPaneWidth : app.treePaneWidth, _minSide);
    final left = clampViews(app.viewsPaneWidth, right);
    right = clampStorage(right, left);
    void setRight(double w) => setState(() => _json ? app.jsonPaneWidth = w : app.treePaneWidth = w);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: left, child: views),
        ResizeHandle(
          label: 'Resize views panel',
          // From the stored width, not this build's: several moves can land in one frame.
          onDrag: (dx) => setState(() => app.viewsPaneWidth = clampViews(clampViews(app.viewsPaneWidth, right) + dx, right)),
          onReset: () => setState(() => app.viewsPaneWidth = AppController.defaultViewsPaneWidth),
        ),
        Expanded(child: center),
        ResizeHandle(
          label: 'Resize storage panel',
          onDrag: (dx) => setRight(clampStorage(clampStorage(_json ? app.jsonPaneWidth : app.treePaneWidth, left) - dx, left)),
          onReset: () => setRight(_json ? AppController.defaultJsonPaneWidth : AppController.defaultTreePaneWidth),
        ),
        SizedBox(width: right, child: storage),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final issues = lintSchema(_draft);
    final view = _view == null ? null : _draft.view(_view!);
    final compact = isCompact(context);

    final center = _Center(
      draft: _draft,
      view: view,
      issues: issues,
      focusRule: _focusRule,
      onRules: _setRules,
      onQuickFix: _quickFix,
      onGoToRule: (v, r) => _selectView(v, rule: r),
      onShowInStorage: _showInStorage,
      onDeleteView: view == null ? null : () => _deleteView(view),
      compactViews: compact ? ViewsSelect(draft: _draft, selected: _view, issues: issues, onSelect: _selectView, onAdd: _addView) : null,
    );
    final storage = StoragePane(
      draft: _draft,
      issues: issues,
      focusPath: _focusPath,
      json: _json,
      onJson: (v) => setState(() => _json = v),
      onStorage: (root) => _update(_draft.copyWith(storage: root)),
      onAdd: _addNode,
      onAddPlaceholder: _addPlaceholder,
      onEdit: _editNode,
      onDelete: _deleteNode,
      compact: compact,
    );

    final play = _playRoute;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          draft: _draft,
          base: widget.base,
          issues: issues,
          playground: play != null,
          onSummary: (v) => _update(_draft.copyWith(summary: v)),
          onNext: _view == null ? null : _openPlayground,
          onBack: _backToEditor,
          onSign: () async {
            await _flush();
            if (context.mounted) openSignDialog(context, _draft, widget.base);
          },
        ),
        Expanded(
          child: play != null
              ? PlaygroundPanel(
                  key: ValueKey('playground:${play.view}'),
                  draft: _draft,
                  snaps: widget.snaps,
                  route: play,
                  onView: (v) {
                    _view = v;
                    context.app.replace(PlaygroundRoute(id, view: v));
                  },
                )
              : compact
              ? SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [center, storage]),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => _resizableRow(
                    constraints.maxWidth,
                    ViewsPane(draft: _draft, selected: _view, issues: issues, onSelect: _selectView, onAdd: _addView),
                    center,
                    storage,
                  ),
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.draft,
    required this.base,
    required this.issues,
    required this.playground,
    required this.onSummary,
    required this.onNext,
    required this.onBack,
    required this.onSign,
  });
  final ConfdbSchema draft;
  final ConfdbSchema? base;
  final List<LintIssue> issues;

  /// On the playground step: Back and Sign & acknowledge instead of Next.
  final bool playground;
  final ValueChanged<String> onSummary;
  final VoidCallback? onNext;
  final VoidCallback onBack;
  final VoidCallback onSign;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final errors = issues.where((i) => i.isError).length;
    final current = playground ? _Stepper.playground : _Stepper.lint;
    final origin = base?.revision == null ? 'Local draft · new schema' : 'Local draft · based on signed rev ${base!.revision}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(draft.id.name, style: context.text.titleMedium?.mono.copyWith(fontWeight: FontWeight.w600)),
                  _SummaryField(summary: draft.summary, onChanged: onSummary),
                  Text(origin, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
              _Stepper(current: current, lintClean: errors == 0),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              lintBadge(issues, prefix: 'Lint: '),
              if (playground) ...[
                TertiaryButton(label: 'Back', icon: AppIcons.back, onPressed: onBack),
                // Playground results are only for trying things; lint errors still block signing.
                PrimaryButton(label: 'Sign & acknowledge', icon: AppIcons.verified, onPressed: errors > 0 ? null : onSign),
              ] else
                Tooltip(
                  message: errors > 0 ? 'Fix the lint errors first' : 'Try the draft in the view playground, then sign',
                  child: PrimaryButton(label: 'Next', icon: AppIcons.next, onPressed: errors > 0 ? null : onNext),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The schema's one-line `summary` header, edited in place.
class _SummaryField extends StatefulWidget {
  const _SummaryField({required this.summary, required this.onChanged});
  final String summary;
  final ValueChanged<String> onChanged;

  @override
  State<_SummaryField> createState() => _SummaryFieldState();
}

class _SummaryFieldState extends State<_SummaryField> {
  late final _text = TextEditingController(text: widget.summary);

  @override
  void didUpdateWidget(_SummaryField old) {
    super.didUpdateWidget(old);
    if (widget.summary != _text.text.trim()) _text.text = widget.summary;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = context.text.bodyMedium;
    // As wide as the text, so the pencil sits right after it.
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 360),
      child: IntrinsicWidth(
        child: Semantics(
          label: 'Schema summary',
          child: TextField(
            controller: _text,
            style: style,
            maxLines: 1,
            onChanged: (v) => widget.onChanged(v.trim()),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              hintText: 'Add a summary',
              hintStyle: style?.copyWith(color: c.onSurfaceVariant),
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.secondary)),
              suffixIcon: Tooltip(
                message: 'Summary',
                child: Icon(AppIcons.edit, size: 16, color: c.onSurfaceVariant),
              ),
              suffixIconConstraints: const BoxConstraints(minWidth: 24, minHeight: 20),
            ),
          ),
        ),
      ),
    );
  }
}

/// Authoring progress: Storage › Views › Lint › Playground › Sign.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.current, required this.lintClean});
  final int current;

  /// The editor sits on Lint; once it's clean the step shows a check.
  final bool lintClean;

  static const lint = 2, playground = 3;
  static const _labels = ['Storage', 'Views', 'Lint', 'Playground', 'Sign'];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: 'Authoring progress: step ${current + 1} of ${_labels.length}, ${_labels[current]}',
      excludeSemantics: true,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            if (i == lint && !lintClean && i < current)
              // Reached the playground with lint errors: Lint isn't done.
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: c.errorContainer),
                child: Icon(AppIcons.error, size: 16, color: c.onErrorContainer),
              )
            else
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < current ? c.secondaryContainer : (i == current ? c.primary : Colors.transparent),
                  border: i > current ? Border.all(color: c.outline) : null,
                ),
                child: i < current || (i == lint && lintClean)
                    ? Icon(AppIcons.check, size: 16, color: i == current ? c.onPrimary : c.onSecondaryContainer)
                    : Text(
                        '${i + 1}',
                        style: context.text.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: i == current ? c.onPrimary : c.onSurfaceVariant,
                        ),
                      ),
              ),
            Text(
              _labels[i],
              style: context.text.bodyMedium?.copyWith(
                fontWeight: i == current ? FontWeight.w600 : FontWeight.w500,
                color: i <= current ? c.onSurface : c.onSurfaceVariant,
              ),
            ),
            if (i < _labels.length - 1) Container(width: 20, height: 1, color: c.outline),
          ],
        ],
      ),
    );
  }
}

class _Center extends StatelessWidget {
  const _Center({
    required this.draft,
    required this.view,
    required this.issues,
    required this.focusRule,
    required this.onRules,
    required this.onQuickFix,
    required this.onGoToRule,
    required this.onShowInStorage,
    required this.onDeleteView,
    required this.compactViews,
  });

  final ConfdbSchema draft;
  final ViewDef? view;
  final List<LintIssue> issues;
  final String? focusRule;
  final ValueChanged<List<ViewRule>> onRules;
  final void Function(String path, StorageNode leaf) onQuickFix;
  final void Function(String view, String? rule) onGoToRule;
  final ValueChanged<String> onShowInStorage;
  final VoidCallback? onDeleteView;
  final Widget? compactViews;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = view;
    final top = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compactViews != null) ...[compactViews!, const SizedBox(height: 16)],
        if (v == null)
          EmptyState(icon: AppIcons.views, title: 'No views yet', body: const Text('Add a view to map request paths to storage.'))
        else ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Semantics(
                          header: true,
                          child: CopyableText(
                            draft.id.view(v.name).path,
                            what: 'view path',
                            style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        StatusBadge.neutral(v.access.label, icon: AccessLabel.iconFor(v.access)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Each rule maps a request path, which snaps and users see, to a storage path, where the data lives.',
                      style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(tooltip: 'Delete view ${v.name}', onPressed: onDeleteView, icon: const Icon(AppIcons.delete)),
            ],
          ),
          const SizedBox(height: 16),
          RulesTable(
            key: ValueKey('rules:${v.name}'),
            view: v,
            storage: draft.storage,
            usage: storageUsage(draft),
            issues: issues.where((i) => i.view == v.name).toList(),
            focusRule: focusRule,
            onChanged: onRules,
            onQuickFix: onQuickFix,
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
    final lint = issues.isEmpty ? null : _LintPanel(issues: issues, onGoToRule: onGoToRule, onShowInStorage: onShowInStorage);
    final padding = const EdgeInsets.fromLTRB(24, 20, 24, 20);
    if (compactViews != null) {
      return Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [top, ?lint]),
      );
    }
    // The rules scroll; lint issues, if any, stay pinned below them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(padding: padding, child: top),
        ),
        if (lint != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 16), child: lint),
      ],
    );
  }
}

/// Lint issues in a slim panel; the list scrolls past a few rows.
class _LintPanel extends StatelessWidget {
  const _LintPanel({required this.issues, required this.onGoToRule, required this.onShowInStorage});
  final List<LintIssue> issues;
  final void Function(String view, String? rule) onGoToRule;
  final ValueChanged<String> onShowInStorage;

  /// Three rows; more issues scroll.
  static const _maxListHeight = 102.0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final errors = issues.where((i) => i.isError).length;
    final warnings = issues.length - errors;
    final summary = [if (errors > 0) plural(errors, 'error'), if (warnings > 0) plural(warnings, 'warning')].join(', ');
    final note = errors > 0 ? 'errors block signing' : 'warnings don’t block signing';
    final linkStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      visualDensity: VisualDensity.compact,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Semantics(header: true, child: Text('Lint', style: context.text.labelLarge)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$summary · $note', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: Scrollbar(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 8),
                children: [
                  for (final i in issues)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 34),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          i.isError ? const StatusBadge.error('Error') : const StatusBadge.warning('Warning'),
                          CodeText(i.message, style: context.text.bodyMedium),
                          if (i.view != null)
                            TextButton(style: linkStyle, onPressed: () => onGoToRule(i.view!, i.request), child: const Text('Go to rule'))
                          else if (i.storagePath != null)
                            TextButton(
                              style: linkStyle,
                              onPressed: () => onShowInStorage(i.storagePath!),
                              child: const Text('Show in storage'),
                            ),
                        ],
                      ),
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

/// Loading state in the editor's own layout, so the page keeps its shape.
class _EditorSkeleton extends StatelessWidget {
  const _EditorSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = context.app;
    Widget pane(double width, List<(double, double)> rows) => Container(
      width: width,
      color: c.surfaceContainerLow,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBar(width: 64, height: 14, strong: true),
          const SizedBox(height: 20),
          for (final (indent, w) in rows) ...[
            Padding(
              padding: EdgeInsets.only(left: indent),
              child: SkeletonBar(width: w),
            ),
            const SizedBox(height: 22),
          ],
        ],
      ),
    );
    const center = Padding(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 260, height: 18, strong: true)),
          SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 420)),
          SizedBox(height: 24),
          TableSkeleton(message: 'Loading schema from snapd…', columns: [3, 5, 2], rows: [0.5, 0.7, 0.4, 0.6, 0.55]),
        ],
      ),
    );
    return Semantics(
      label: 'Loading schema',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(minHeight: 3),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.outlineVariant)),
            ),
            child: const Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [SkeletonBar(width: 110, height: 14, strong: true), SizedBox(height: 8), SkeletonBar(width: 170, height: 10)],
                ),
                SizedBox(width: 32),
                SkeletonBar(width: 360, height: 14),
              ],
            ),
          ),
          Expanded(
            child: isCompact(context)
                ? const SingleChildScrollView(child: center)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      pane(app.viewsPaneWidth, const [(0, 150), (16, 110), (16, 90), (16, 120), (0, 140), (0, 130)]),
                      VerticalDivider(width: ResizeHandle.width, color: c.outlineVariant),
                      const Expanded(child: SingleChildScrollView(child: center)),
                      VerticalDivider(width: ResizeHandle.width, color: c.outlineVariant),
                      pane(app.treePaneWidth, const [(0, 90), (20, 160), (20, 130), (20, 150), (20, 170), (0, 100), (20, 140), (20, 120)]),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
