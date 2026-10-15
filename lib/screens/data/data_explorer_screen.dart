import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../shell/app_shell.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';
import '../../widgets/loader.dart';
import '../../widgets/status_badge.dart';
import 'entry_detail.dart';
import 'view_values.dart';
import '../../state/account_names.dart';

/// Everything the explorer needs besides the values themselves.
class ExplorerContext {
  const ExplorerContext(this.schemas, this.snaps, this.changes);
  final List<ConfdbSchema> schemas;
  final List<SnapInfo> snaps;
  final List<ConfdbChange> changes;

  List<ViewRef> get views => [
    for (final s in schemas)
      for (final v in s.views) s.id.view(v.name),
  ];

  ConfdbSchema? schema(SchemaId id) => schemas.where((s) => s.id == id).firstOrNull;

  /// First writable view of a non-built-in schema: where operators usually start.
  ViewRef? get defaultView {
    for (final s in schemas.where((s) => !s.builtIn)) {
      for (final v in s.views) {
        if (v.rules.any((r) => r.access.canWrite)) return s.id.view(v.name);
      }
    }
    return views.firstOrNull;
  }
}

Future<ExplorerContext> _loadContext(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listSnaps(), repo.listChanges()]);
  return ExplorerContext(r[0] as List<ConfdbSchema>, r[1] as List<SnapInfo>, r[2] as List<ConfdbChange>);
}

/// 7.6 Data explorer: browse and edit values through a view.
class DataExplorerScreen extends StatelessWidget {
  const DataExplorerScreen({super.key, required this.route});
  final DataRoute route;

  @override
  Widget build(BuildContext context) => Loader<ExplorerContext>(
    load: _loadContext,
    loading: (context) => const Padding(
      padding: EdgeInsets.all(24),
      child: TableSkeleton(message: 'Loading views from snapd…', columns: [3, 2, 5, 2], rows: [0.5, 0.7, 0.4, 0.6]),
    ),
    error: (context, e, retry) => Padding(
      padding: const EdgeInsets.all(24),
      child: LoadErrorMessage(title: 'Couldn’t load views', error: e, onRetry: retry, command: 'systemctl status snapd.service'),
    ),
    builder: (context, ctx, reload) => _Explorer(route: route, ctx: ctx, onReloadContext: reload),
  );
}

class _Explorer extends StatefulWidget {
  const _Explorer({required this.route, required this.ctx, required this.onReloadContext});
  final DataRoute route;
  final ExplorerContext ctx;

  /// Re-reads schemas, snaps and changes (keeping what's on screen meanwhile).
  final VoidCallback onReloadContext;

  @override
  State<_Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends State<_Explorer> {
  late final _search = TextEditingController(text: widget.route.query ?? '');

  /// Bumped to re-read values; part of the values loader's key.
  int _generation = 0;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _reload);

  /// Re-reads schemas and values from snapd, e.g. after a revision was
  /// acknowledged outside the app. Staged edits and the search are kept.
  void _reload() {
    widget.onReloadContext();
    setState(() => _generation++);
  }

  @override
  void initState() {
    super.initState();
    _lifecycle; // reload when the window comes back to the foreground
    _search.addListener(() => setState(() {}));
    final r = widget.route;
    if (r.view == null) {
      final v = widget.ctx.defaultView;
      if (v != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.app.replace(DataRoute(view: v, query: r.query));
        });
      }
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final route = widget.route;
    final view = route.view ?? widget.ctx.defaultView;
    final compact = isCompact(context);
    final query = _search.text.trim();

    final toolbar = _Toolbar(ctx: widget.ctx, view: view, search: _search, onReload: _reload);

    Widget body;
    if (view == null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyState(
          icon: AppIcons.data,
          title: 'No views on this device',
          body: const Text('Acknowledge a schema to read and write values through its views.'),
          actions: [SecondaryButton(label: 'Go to schemas', onPressed: () => app.go(const SchemasRoute()))],
        ),
      );
    } else {
      body = Loader<ViewSnapshot>(
        key: ValueKey('view:${view.path}:$_generation'),
        load: (repo) => repo.readView(view),
        loading: (context) =>
            _split(compact, const TableSkeleton(message: 'Reading values…', columns: [3, 2, 5, 2], rows: [0.5, 0.7, 0.4, 0.6]), null),
        error: (context, e, retry) => _split(
          compact,
          LoadErrorMessage(title: 'Couldn’t read ${view.path}', error: e, onRetry: retry, command: 'snap get ${view.path}'),
          null,
        ),
        builder: (context, snap, reload) {
          final selected =
              snap.entries.where((e) => e.key == route.key).firstOrNull ??
              (query.isEmpty ? null : snap.entries.where((e) => matchesQuery(e, query)).firstOrNull) ??
              snap.entries.firstOrNull;
          return ListenableBuilder(
            listenable: context.staging,
            builder: (context, _) => _split(
              compact,
              ViewValues(
                snapshot: snap,
                selected: selected?.key,
                query: query,
                compact: compact,
                ctx: widget.ctx,
                onSelect: (key) => app.replace(DataRoute(view: view, key: key, query: route.query)),
                onReload: reload,
                onEditSibling: (ref) => app.go(DataRoute(view: ref)),
              ),
              snap.isEmpty || selected == null
                  ? null
                  : EntryDetail(key: ValueKey('${view.path}/${selected.key}'), snapshot: snap, entry: selected, ctx: widget.ctx),
            ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        Expanded(child: body),
      ],
    );
  }

  /// Values on the left with the detail panel on the right, or stacked when compact.
  Widget _split(bool compact, Widget values, Widget? detail) {
    final c = context.colors;
    final valuesPad = Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 24), child: values);
    if (compact) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            valuesPad,
            if (detail != null)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: c.surfaceContainerLow,
                  border: Border(top: BorderSide(color: c.outlineVariant)),
                ),
                child: detail,
              ),
          ],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: SingleChildScrollView(child: valuesPad)),
        if (detail != null)
          Container(
            width: 380,
            decoration: BoxDecoration(
              color: c.surfaceContainerLow,
              border: Border(left: BorderSide(color: c.outlineVariant)),
            ),
            child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: detail),
          ),
      ],
    );
  }
}

/// Matches keys and storage paths, case-insensitively.
bool matchesQuery(ViewEntry e, String q) {
  final l = q.toLowerCase();
  return e.key.toLowerCase().contains(l) || e.rule.storage.toLowerCase().contains(l);
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.ctx, required this.view, required this.search, required this.onReload});

  final ExplorerContext ctx;
  final ViewRef? view;
  final TextEditingController search;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = context.app;
    final query = search.text.trim();
    final def = view == null ? null : ctx.schema(view!.schemaId)?.view(view!.view);

    final selector = OutlinedSelect<ViewRef>(
      label: 'View',
      items: [
        for (final ref in ctx.views)
          (
            ref,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.aliased(ref.path), style: context.text.bodyLarge?.mono.copyWith(fontSize: 15)),
                const SizedBox(width: 16),
                Text(
                  ctx.schema(ref.schemaId)?.view(ref.view)?.access.label ?? '',
                  style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
      onSelected: (ref) => app.replace(DataRoute(view: ref)),
      child: Row(
        children: [
          Expanded(child: Text(view == null ? 'No views' : context.aliased(view!.path), overflow: TextOverflow.ellipsis)),
          if (def != null)
            StatusBadge.neutral(def.access.label, icon: def.access == RuleAccess.readWrite ? AppIcons.readWrite : AppIcons.eye),
        ],
      ),
    );

    String help = 'Matches keys and storage paths in all views';
    if (query.isNotEmpty) {
      final hereCount = def?.rules.where((r) => r.request.contains(query) || r.storage.contains(query)).length ?? 0;
      final elsewhere = [
        for (final ref in ctx.views)
          if (ref != view &&
              (ctx.schema(ref.schemaId)?.view(ref.view)?.rules.any((r) => r.request.contains(query) || r.storage.contains(query)) ?? false))
            ref.view,
      ];
      help = [
        hereCount == 0 ? 'No match here' : '$hereCount ${hereCount == 1 ? 'match' : 'matches'} here',
        if (elsewhere.isNotEmpty) 'also in ${elsewhere.join(', ')}',
      ].join(' · ');
    }

    final searchField = TextField(
      controller: search,
      style: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
      decoration: InputDecoration(
        labelText: 'Search keys across all views',
        helperText: help,
        prefixIcon: const Icon(AppIcons.search),
        suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Clear search', onPressed: search.clear, icon: const Icon(AppIcons.close)),
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
      ),
    );
    final reload = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IconButton(tooltip: 'Reload schemas and values from snapd', onPressed: onReload, icon: const Icon(AppIcons.retry)),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          SizedBox(width: 400, child: selector),
          SizedBox(width: 420, child: searchField),
          reload,
        ],
      ),
    );
  }
}
