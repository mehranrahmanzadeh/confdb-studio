import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../schemas/schemas_section.dart';
import '../../state/account_names.dart';

class _OverviewData {
  const _OverviewData(this.schemas, this.drafts, this.snaps);
  final List<ConfdbSchema> schemas;
  final List<ConfdbSchema> drafts;
  final List<SnapInfo> snaps;
}

Future<_OverviewData> _load(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listDrafts(), repo.listSnaps()]);
  return _OverviewData(r[0] as List<ConfdbSchema>, r[1] as List<ConfdbSchema>, r[2] as List<SnapInfo>);
}

/// 7.2 Overview (Main.dc.html, Main-Rev5, Main-Compact): the counts, every
/// schema (the former 7.3 Schemas list).
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader<_OverviewData>(
      load: _load,
      loading: (context) => const PageBody(children: [_Header(), SchemasSection(data: null)]),
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
        note: [if (own > 0) '$own in ${context.accounts?.alias(account) ?? account}', if (builtIn > 0) '$builtIn built-in'].join(' · '),
      ),
      _Tile(
        icon: AppIcons.views,
        label: 'Views',
        value: '$viewCount',
        note: schemas.map((s) => '${s.id.name} ${s.views.length}').join(' · '),
      ),
    ];

    return PageBody(
      children: [
        const _Header(),
        AutoGrid(minItemWidth: 180, children: tiles),
        SchemasSection(data: SchemasData(schemas, data.drafts, snaps)),
      ],
    );
  }
}

/// A count card. Not a button: the schemas table below has the details.
class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.value, required this.note});
  final IconData icon;
  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = c.onSurfaceVariant;
    return Semantics(
      container: true,
      label: '$label: $value. $note',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(ConfdbRadii.card)),
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
    );
  }
}
