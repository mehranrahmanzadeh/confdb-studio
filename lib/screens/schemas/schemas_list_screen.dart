import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/fields.dart';
import '../../widgets/loader.dart';
import '../../widgets/status_badge.dart';
import '../access/custodian_guide.dart';

class _SchemasData {
  const _SchemasData(this.schemas, this.drafts, this.snaps);
  final List<ConfdbSchema> schemas;
  final List<ConfdbSchema> drafts;
  final List<SnapInfo> snaps;
}

Future<_SchemasData> _load(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listDrafts(), repo.listSnaps()]);
  return _SchemasData(r[0] as List<ConfdbSchema>, r[1] as List<ConfdbSchema>, r[2] as List<SnapInfo>);
}

/// Picks an assertion or JSON draft and imports it, then opens the editor.
Future<void> importSchemaFromDisk(BuildContext context) async {
  final scope = context.scope;
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Schemas', extensions: ['assert', 'json']),
      XTypeGroup(label: 'All files'),
    ],
  );
  if (file == null) return;
  try {
    final draft = await scope.repository.importSchema(file.path);
    scope.app.go(SchemaEditorRoute(draft.id));
  } catch (e) {
    if (context.mounted) showConfirmation(context, Text('Couldn’t import ${file.name}: $e'));
  }
}

/// 7.3 Schemas (SchemasList.dc.html, -Empty, -Loading, -Error).
class SchemasListScreen extends StatefulWidget {
  const SchemasListScreen({super.key});

  @override
  State<SchemasListScreen> createState() => _SchemasListScreenState();
}

class _SchemasListScreenState extends State<SchemasListScreen> {
  final _search = TextEditingController();
  bool _problems = false;
  bool _draftsOnly = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Loader<_SchemasData>(
        load: _load,
        loading: (context) => PageBody(
          gap: 20,
          children: [
            const _Header(),
            _toolbar(context, null),
            const TableSkeleton(message: 'Loading schemas from snapd…', columns: [3, 5, 1, 2, 2], rows: [0.7, 0.55, 0.4, 0.65, 0.5]),
          ],
        ),
        error: (context, e, retry) => PageBody(
          gap: 20,
          children: [
            const _Header(),
            _toolbar(context, null),
            LoadErrorMessage(
              title: 'Couldn’t load schemas',
              error: '$e Values you staged are kept.',
              onRetry: retry,
              command: 'systemctl status snapd.service',
            ),
          ],
        ),
        builder: (context, data, _) => PageBody(gap: 20, children: [const _Header(), _toolbar(context, data), _body(context, data)]),
      ),
    );
  }

  Widget _toolbar(BuildContext context, _SchemasData? data) {
    final app = context.app;
    final c = context.colors;
    final withProblems = data == null ? 0 : _merged(data).where((s) => lintSchema(s).isNotEmpty).length;
    final drafts = data?.drafts.length ?? 0;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                controller: _search,
                enabled: data != null,
                decoration: const InputDecoration(
                  hintText: 'Search schemas',
                  prefixIcon: Icon(AppIcons.search),
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            FilterChip(
              avatar: Icon(AppIcons.warning, size: 18, color: c.onSurfaceVariant),
              label: Text('Has problems · $withProblems'),
              selected: _problems,
              onSelected: data == null ? null : (v) => setState(() => _problems = v),
            ),
            FilterChip(
              avatar: Icon(AppIcons.edit, size: 18, color: c.onSurfaceVariant),
              label: Text('Drafts · $drafts'),
              selected: _draftsOnly,
              onSelected: data == null ? null : (v) => setState(() => _draftsOnly = v),
            ),
          ],
        ),
        PrimaryButton(label: 'New schema', icon: AppIcons.add, onPressed: () => app.go(const OnboardingRoute(choose: true))),
      ],
    );
  }

  /// Acknowledged schemas, with drafts of new schemas appended.
  List<ConfdbSchema> _merged(_SchemasData d) => [
    ...d.schemas,
    for (final draft in d.drafts)
      if (!d.schemas.any((s) => s.id == draft.id)) draft,
  ];

  Widget _body(BuildContext context, _SchemasData data) {
    final app = context.app;
    final all = _merged(data);
    if (all.isEmpty) {
      return EmptyState(
        icon: AppIcons.schemas,
        title: 'No schemas yet',
        body: const Text(
          'A schema defines the typed settings snaps can read and write. Import a signed assertion, or create one from a template.',
        ),
        actions: [
          SecondaryButton(label: 'Import', icon: AppIcons.upload, onPressed: () => importSchemaFromDisk(context)),
          PrimaryButton(label: 'Create schema', icon: AppIcons.add, onPressed: () => app.go(const OnboardingRoute(choose: true))),
        ],
        command: 'sudo snap ack network.assert',
      );
    }
    final q = _search.text.trim().toLowerCase();
    final draftIds = {for (final d in data.drafts) d.id};
    final shown = all.where((s) {
      if (q.isNotEmpty && !s.id.path.toLowerCase().contains(q) && !s.summary.toLowerCase().contains(q)) return false;
      if (_draftsOnly && !draftIds.contains(s.id)) return false;
      if (_problems && lintSchema(data.drafts.where((d) => d.id == s.id).firstOrNull ?? s).isEmpty) return false;
      return true;
    }).toList();
    if (shown.isEmpty) {
      return EmptyState(
        icon: AppIcons.search,
        title: 'No schemas match',
        body: Text('${plural(all.length, 'schema')} in total.'),
        actions: [
          SecondaryButton(
            label: 'Clear filters',
            onPressed: () => setState(() {
              _search.clear();
              _problems = _draftsOnly = false;
            }),
          ),
        ],
      );
    }
    final groups = <String, List<ConfdbSchema>>{};
    for (final s in shown) {
      groups.putIfAbsent(s.id.account, () => []).add(s);
    }
    return _SchemaTable(groups: groups, data: data);
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const PageHeader(
    title: 'Schemas',
    subtitle: Text('Signed confdb-schema assertions acknowledged on this device, and your local drafts.'),
  );
}

class _SchemaTable extends StatelessWidget {
  const _SchemaTable({required this.groups, required this.data});
  final Map<String, List<ConfdbSchema>> groups;
  final _SchemasData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final head = tableHeaderStyle(context);
    Widget cells(List<Widget> w) => Row(
      children: [
        Expanded(flex: 10, child: w[0]),
        const SizedBox(width: 16),
        Expanded(flex: 16, child: w[1]),
        const SizedBox(width: 16),
        SizedBox(width: 80, child: w[2]),
        const SizedBox(width: 16),
        SizedBox(width: 56, child: w[3]),
        const SizedBox(width: 16),
        Expanded(flex: 10, child: w[4]),
        const SizedBox(width: 16),
        Expanded(flex: 12, child: w[5]),
        const SizedBox(width: 16),
        Expanded(flex: 10, child: w[6]),
        SizedBox(width: 40, child: w[7]),
      ],
    );

    return Semantics(
      label: 'Schemas by account',
      container: true,
      child: SectionCard(
        child: MinWidthScroll(
          minWidth: 1080,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outlineVariant)),
                ),
                child: cells([
                  for (final h in ['Name', 'Summary', 'Revision', 'Views', 'Custodian', 'Signature', 'Lint']) Text(h, style: head),
                  const SizedBox.shrink(),
                ]),
              ),
              for (final g in groups.entries) ...[
                GroupHeaderRow(
                  minHeight: 40,
                  child: Row(
                    children: [
                      Text(g.key, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      Text(
                        g.value.every((s) => s.builtIn)
                            ? '${plural(g.value.length, 'schema')} · built-in, read-only'
                            : plural(g.value.length, 'schema'),
                        style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                for (final s in g.value) _row(context, s, cells),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ConfdbSchema s, Widget Function(List<Widget>) cells) {
    final c = context.colors;
    final draft = data.drafts.where((d) => d.id == s.id).firstOrNull;
    final linted = draft ?? s;
    final custodians = custodiansOf(s.id, data.snaps);
    final open = s.builtIn ? null : () => context.app.go(SchemaEditorRoute(s.id));
    return Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: cells([
        Align(
          alignment: Alignment.centerLeft,
          child: open == null
              ? Text(s.id.name, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500))
              : TextButton(
                  onPressed: open,
                  style: TextButton.styleFrom(
                    foregroundColor: c.onSurface,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 40),
                    textStyle: context.text.bodyMedium?.mono.copyWith(
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                      decorationColor: c.outlineVariant,
                    ),
                  ),
                  child: Text(s.id.name),
                ),
        ),
        Text(s.summary, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
        Text(s.builtIn ? 'built-in' : (s.revision == null ? 'draft' : 'rev ${s.revision}'), style: context.text.bodyMedium?.mono),
        Text('${s.views.length}', style: context.text.bodyMedium),
        if (!s.builtIn && custodians.isNotEmpty)
          Text(custodians.map((p) => p.snap).toSet().join(', '), style: context.text.bodyMedium?.mono)
        else
          Align(
            alignment: Alignment.centerLeft,
            child: CustodianBadge(schema: draft ?? s, snaps: data.snaps, short: true),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (s.builtIn)
              const StatusBadge.neutral('Built-in', icon: AppIcons.lock)
            else if (s.revision != null)
              const StatusBadge.success('Signed', icon: AppIcons.verified)
            else
              // Only a draft so far: nothing signed yet.
              const StatusBadge.info('Local draft', icon: AppIcons.edit),
          ],
        ),
        Align(alignment: Alignment.centerLeft, child: lintBadge(lintSchema(linted))),
        if (draft == null)
          const SizedBox.shrink()
        else
          PopupMenuButton<void>(
            tooltip: 'Actions for ${s.id.path}',
            icon: const Icon(Icons.more_vert),
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: () => _discard(context, draft),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(AppIcons.delete, color: c.error),
                  title: Text(draft.baseRevision == null ? 'Delete draft' : 'Discard draft'),
                ),
              ),
            ],
          ),
      ]),
    );
  }

  /// Drops the local draft. Signed revisions stay: snapd can't remove them.
  Future<void> _discard(BuildContext context, ConfdbSchema draft) async {
    final repo = context.repo;
    final isNew = draft.baseRevision == null;
    final ok = await confirmDestructive(
      context,
      title: Text(isNew ? 'Delete draft ${draft.id.path}?' : 'Discard draft of ${draft.id.path}?'),
      action: isNew ? 'Delete draft' : 'Discard draft',
      body: Text(
        isNew
            ? 'It was never signed, so it exists only as this local draft. This can’t be undone.'
            : 'Unsigned changes are lost. Revision ${draft.baseRevision} stays acknowledged on this device.',
      ),
    );
    if (!ok) return;
    await repo.discardDraft(draft.id);
    if (context.mounted) showConfirmation(context, Text(isNew ? 'Deleted draft ${draft.id.path}' : 'Discarded draft of ${draft.id.path}'));
  }
}
