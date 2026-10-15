import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/fields.dart';
import '../../widgets/loader.dart';
import '../../state/account_names.dart';

/// Identifiers in a change summary, e.g. `browser-proxy:proxy-state`.
Iterable<String> _codes(String s) sync* {
  final parts = s.split('`');
  for (var i = 1; i < parts.length; i += 2) {
    yield parts[i];
  }
}

String? changeSchema(ConfdbChange c) {
  if (c.view != null) return c.view!.schemaId.path;
  for (final code in _codes(c.summary)) {
    final p = code.split('/');
    if (p.length >= 2 && !code.contains(':')) return '${p[0]}/${p[1]}';
  }
  return null;
}

Set<String> changeSnaps(ConfdbChange c) => {
  if (c.initiatorKind == InitiatorKind.snap) c.initiator,
  ?c.custodian,
  ...c.observers,
  for (final code in _codes(c.summary))
    if (code.contains(':')) code.split(':').first,
};

/// 7.10 Activity (Activity.dc.html, -Empty, -Loading).
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  String? _schema, _view, _snap, _status;

  bool get _filtered => _schema != null || _view != null || _snap != null || _status != null;

  @override
  Widget build(BuildContext context) {
    final header = PageHeader(
      title: 'Activity',
      subtitle: const Text('Every confdb write, connection and acknowledgement is a snapd change.'),
      trailing: const CliDisclosure('snap changes'),
    );
    return Loader<List<ConfdbChange>>(
      load: (repo) => repo.listChanges(),
      loading: (context) => PageBody(
        gap: 16,
        children: [
          header,
          _filters(const []),
          const TableSkeleton(message: 'Loading changes from snapd…', columns: [1, 6, 2, 1, 2]),
        ],
      ),
      error: (context, e, retry) => PageBody(
        gap: 16,
        children: [
          header,
          LoadErrorMessage(title: 'Couldn’t load changes', error: e, onRetry: retry, command: 'snap changes'),
        ],
      ),
      builder: (context, changes, _) {
        final shown = changes.where((c) {
          if (_schema != null && changeSchema(c) != _schema) return false;
          if (_view != null && c.view?.path != _view) return false;
          if (_snap != null && !changeSnaps(c).contains(_snap)) return false;
          if (_status != null && c.status.label != _status) return false;
          return true;
        }).toList();
        return PageBody(
          gap: 16,
          children: [
            header,
            _filters(changes),
            if (changes.isEmpty)
              EmptyState(
                icon: AppIcons.activity,
                title: 'No changes yet',
                body: const Text('Changes appear here when values are set, snaps connect to views, or a schema is acknowledged.'),
                actions: [
                  SecondaryButton(label: 'Open Data explorer', icon: AppIcons.data, onPressed: () => context.app.go(const DataRoute())),
                ],
              )
            else if (shown.isEmpty)
              EmptyState(
                icon: AppIcons.search,
                title: 'No changes match these filters',
                body: Text('${plural(changes.length, 'change')} in total.'),
                actions: [
                  SecondaryButton(label: 'Clear filters', onPressed: () => setState(() => _schema = _view = _snap = _status = null)),
                ],
              )
            else
              _ChangesTable(changes: shown),
          ],
        );
      },
    );
  }

  Widget _filters(List<ConfdbChange> changes) {
    List<String> sorted(Iterable<String?> xs) => ({for (final x in xs) ?x}.toList()..sort());
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterMenuChip(
          label: 'Schema',
          monoOptions: true,
          options: sorted(changes.map(changeSchema)),
          value: _schema,
          onChanged: (v) => setState(() => _schema = v),
        ),
        FilterMenuChip(
          label: 'View',
          monoOptions: true,
          options: sorted(changes.map((c) => c.view?.path)),
          value: _view,
          onChanged: (v) => setState(() => _view = v),
        ),
        FilterMenuChip(
          label: 'Snap',
          monoOptions: true,
          options: sorted(changes.expand(changeSnaps)),
          value: _snap,
          onChanged: (v) => setState(() => _snap = v),
        ),
        FilterMenuChip(
          label: 'Status',
          options: sorted(changes.map((c) => c.status.label)),
          value: _status,
          onChanged: (v) => setState(() => _status = v),
        ),
        if (_filtered)
          TextButton(onPressed: () => setState(() => _schema = _view = _snap = _status = null), child: const Text('Clear filters')),
      ],
    );
  }
}

class _ChangesTable extends StatelessWidget {
  const _ChangesTable({required this.changes});
  final List<ConfdbChange> changes;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final head = tableHeaderStyle(context);
    Widget cells(Widget id, Widget summary, Widget who, Widget time, Widget status) => Row(
      children: [
        SizedBox(width: 72, child: id),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: summary),
        const SizedBox(width: 16),
        Expanded(child: who),
        const SizedBox(width: 16),
        SizedBox(width: 96, child: time),
        const SizedBox(width: 16),
        SizedBox(width: 140, child: status),
      ],
    );

    final groups = <String, List<ConfdbChange>>{};
    for (final ch in changes) {
      groups.putIfAbsent(dayGroup(ch.spawnTime), () => []).add(ch);
    }

    return Semantics(
      label: 'Changes',
      container: true,
      child: SectionCard(
        child: MinWidthScroll(
          minWidth: 960,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outlineVariant)),
                ),
                child: cells(
                  Text('ID', style: head),
                  Text('Summary', style: head),
                  Text('Initiated by', style: head),
                  Text('Time', style: head),
                  Text('Status', style: head),
                ),
              ),
              for (final g in groups.entries) ...[
                GroupHeaderRow(
                  child: Text(
                    g.key,
                    style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: c.onSurfaceVariant),
                  ),
                ),
                for (final ch in g.value)
                  Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.outlineVariant)),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        mouseCursor: WidgetStateMouseCursor.clickable,
                        onTap: () => context.app.go(ChangeRoute(ch.id)),
                        child: Semantics(
                          button: true,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: cells(
                                Text('#${ch.id}', style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w600)),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CodeText(ch.summary, style: context.text.bodyMedium),
                                    if (ch.detail != null)
                                      Text(
                                        context.aliased(ch.detail!),
                                        style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant),
                                      ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Icon(
                                      ch.initiatorKind == InitiatorKind.snap ? AppIcons.snap : AppIcons.user,
                                      size: 18,
                                      color: c.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            ch.initiator,
                                            style: ch.initiatorKind == InitiatorKind.snap
                                                ? context.text.bodyMedium?.mono
                                                : context.text.bodyMedium,
                                          ),
                                          Text(
                                            ch.initiatorKind == InitiatorKind.snap ? 'Snap' : 'User',
                                            style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                Text(hm(ch.spawnTime), style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ChangeBadge(ch.status),
                                    if (ch.status == ChangeStatus.doing && ch.progressTotal > 0) ...[
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        width: 110,
                                        child: Semantics(
                                          label: 'Change ${ch.id} progress',
                                          value: '${ch.progressDone} of ${ch.progressTotal}',
                                          child: LinearProgressIndicator(
                                            value: ch.progressDone / ch.progressTotal,
                                            minHeight: 4,
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
