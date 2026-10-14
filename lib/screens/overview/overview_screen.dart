import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../access/custodian_guide.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/loader.dart';
import '../../widgets/status_badge.dart';

class _OverviewData {
  const _OverviewData(this.schemas, this.snaps, this.changes);
  final List<ConfdbSchema> schemas;
  final List<SnapInfo> snaps;
  final List<ConfdbChange> changes;
}

Future<_OverviewData> _load(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listSnaps(), repo.listChanges()]);
  return _OverviewData(r[0] as List<ConfdbSchema>, r[1] as List<SnapInfo>, r[2] as List<ConfdbChange>);
}

/// 7.2 Overview (Main.dc.html, Main-Rev5, Main-Compact).
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader<_OverviewData>(
      load: _load,
      loading: (context) => const PageBody(
        children: [
          _Header(),
          TableSkeleton(message: 'Loading from snapd…', columns: [2, 5, 2, 2], rows: [0.6, 0.5, 0.7, 0.4]),
        ],
      ),
      error: (context, e, retry) => PageBody(
        children: [
          const _Header(),
          LoadErrorMessage(title: 'Couldn’t load the overview', error: e, onRetry: retry, command: 'systemctl status snapd.service'),
        ],
      ),
      builder: (context, d, _) => _OverviewBody(data: d),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PageHeader(
      title: 'Overview',
      trailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          SecondaryButton(label: 'Manage access', icon: AppIcons.access, onPressed: () => app.go(const AccessRoute())),
          PrimaryButton(label: 'New schema', icon: AppIcons.add, onPressed: () => app.go(const OnboardingRoute(choose: true))),
        ],
      ),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.data});
  final _OverviewData data;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final account = app.account;
    final schemas = data.schemas;
    final snaps = data.snaps;
    final viewCount = schemas.fold(0, (n, s) => n + s.views.length);
    final own = schemas.where((s) => s.id.account == account).length;
    final builtIn = schemas.where((s) => s.builtIn).length;

    final tiles = [
      _Tile(
        icon: AppIcons.schemas,
        label: 'Schemas',
        value: '${schemas.length}',
        note: [if (own > 0) '$own in $account', if (builtIn > 0) '$builtIn built-in'].join(' · '),
        onTap: () => app.go(const SchemasRoute()),
      ),
      _Tile(
        icon: AppIcons.views,
        label: 'Views',
        value: '$viewCount',
        note: schemas.map((s) => '${s.id.name} ${s.views.length}').join(' · '),
        onTap: () {
          final first = schemas.where((s) => !s.builtIn).firstOrNull;
          app.go(first == null ? const SchemasRoute() : SchemaEditorRoute(first.id));
        },
      ),
    ];

    return PageBody(
      children: [
        const _Header(),
        AutoGrid(minItemWidth: 180, children: tiles),
        AutoGrid(
          minItemWidth: 420,
          spacing: 24,
          stretch: false,
          children: [
            _RecentActivity(changes: data.changes.take(4).toList()),
            _SchemaList(schemas: schemas, snaps: snaps, changes: data.changes),
          ],
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.value, required this.note, required this.onTap});
  final IconData icon;
  final String label;
  final String value;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = c.onSurfaceVariant;
    return Material(
      color: c.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.card)),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.card)),
        child: Semantics(
          button: true,
          label: '$label: $value. $note',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20, color: muted),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(value, style: context.text.displaySmall?.copyWith(color: c.onSurface)),
                const SizedBox(height: 4),
                Text(note, style: context.text.bodySmall?.copyWith(color: muted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentActivity extends StatelessWidget {
  const _RecentActivity({required this.changes});
  final List<ConfdbChange> changes;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Recent activity',
          action: TextButton(onPressed: () => app.go(const ActivityRoute()), child: const Text('View all')),
        ),
        const SizedBox(height: 12),
        if (changes.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text('No changes yet.', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          )
        else
          SectionCard(
            child: Column(
              children: [
                for (var i = 0; i < changes.length; i++)
                  ListRow(
                    first: i == 0,
                    onTap: () => app.go(ChangeRoute(changes[i].id)),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 76,
                          child: Align(alignment: Alignment.centerLeft, child: ChangeBadge(changes[i].status)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text.rich(
                                TextSpan(
                                  style: context.text.bodyMedium,
                                  children: [
                                    TextSpan(
                                      text: '#${changes[i].id} ',
                                      style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500),
                                    ),
                                    ...CodeText.spans(changes[i].summary, context.text.bodyMedium!),
                                  ],
                                ),
                              ),
                              if (changes[i].detail != null)
                                Text(changes[i].detail!, style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(shortTime(changes[i].spawnTime), style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SchemaList extends StatelessWidget {
  const _SchemaList({required this.schemas, required this.snaps, required this.changes});
  final List<ConfdbSchema> schemas;
  final List<SnapInfo> snaps;
  final List<ConfdbChange> changes;

  /// Acknowledged today: shows a "New revision" badge (Main-Rev5).
  bool _newRevision(ConfdbSchema s) {
    final now = DateTime.now();
    return changes.any(
      (c) =>
          c.kind == 'ack-schema' &&
          c.status == ChangeStatus.done &&
          c.summary.contains('`${s.id.path}` rev ${s.revision}') &&
          now.difference(c.spawnTime).inHours < 12,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Schemas',
          action: TextButton(onPressed: () => app.go(const SchemasRoute()), child: const Text('All schemas')),
        ),
        const SizedBox(height: 12),
        if (schemas.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text('No schemas on this device yet.', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          )
        else
          SectionCard(
            child: Column(children: [for (var i = 0; i < schemas.length; i++) _schemaRow(context, schemas[i], first: i == 0)]),
          ),
      ],
    );
  }

  Widget _schemaRow(BuildContext context, ConfdbSchema s, {required bool first}) {
    final c = context.colors;
    final issues = lintSchema(s);
    final meta = s.builtIn
        ? 'built-in · ${plural(s.views.length, 'view')} · read-only'
        : 'rev ${s.revision} · ${plural(s.views.length, 'view')} · ${s.signedBy != null ? 'signed' : 'unsigned'}';
    final isNew = _newRevision(s);
    return ListRow(
      first: first,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: () => context.app.go(s.builtIn ? const SchemasRoute() : SchemaEditorRoute(s.id)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.id.path, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
                Text(meta, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isNew) ...[const StatusBadge.info('New revision'), const SizedBox(width: 12)],
          if (!isNew && issues.isNotEmpty) ...[lintBadge(issues), const SizedBox(width: 12)],
          CustodianBadge(schema: s, snaps: snaps),
        ],
      ),
    );
  }
}
