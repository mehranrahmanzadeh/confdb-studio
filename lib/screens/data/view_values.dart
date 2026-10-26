import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/access.dart';
import '../../domain/values.dart';
import '../../state/app_scope.dart';
import '../../state/staging_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/chips.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';
import '../../widgets/status_badge.dart';
import 'data_explorer_screen.dart';
import '../../state/account_names.dart';

/// The values table of one view (plus the load-view error and empty state).
class ViewValues extends StatefulWidget {
  const ViewValues({
    super.key,
    required this.snapshot,
    required this.selected,
    required this.query,
    required this.compact,
    required this.ctx,
    required this.onSelect,
    required this.onReload,
    required this.onEditSibling,
  });

  final ViewSnapshot snapshot;
  final String? selected;
  final String query;
  final bool compact;
  final ExplorerContext ctx;
  final ValueChanged<String> onSelect;
  final VoidCallback onReload;
  final ValueChanged<ViewRef> onEditSibling;

  @override
  State<ViewValues> createState() => _ViewValuesState();
}

class _ViewValuesState extends State<ViewValues> {
  bool _collapsed = false;

  ViewSnapshot get snapshot => widget.snapshot;
  String? get selected => widget.selected;
  String get query => widget.query;
  bool get compact => widget.compact;
  ExplorerContext get ctx => widget.ctx;
  ValueChanged<String> get onSelect => widget.onSelect;
  VoidCallback get onReload => widget.onReload;
  ValueChanged<ViewRef> get onEditSibling => widget.onEditSibling;

  @override
  void didUpdateWidget(ViewValues old) {
    super.didUpdateWidget(old);
    // A different view: start expanded again rather than keep a stale
    // collapse state from the previous view.
    if (old.snapshot.ref != widget.snapshot.ref) _collapsed = false;
  }

  @override
  Widget build(BuildContext context) {
    final staging = context.staging;
    final failure = snapshot.loadFailure;
    final children = <Widget>[
      if (failure != null) _LoadFailure(failure: failure, onRetry: onReload),
      if (snapshot.isEmpty) _empty(context) else _table(context, staging),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 12), children[i]],
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final ref = snapshot.ref;
    final keys = snapshot.entries.map((e) => '`${e.key}`').toList();
    final exposes = keys.length <= 1 ? keys.join() : '${keys.sublist(0, keys.length - 1).join(', ')} and ${keys.last}';
    final custodian = custodiansFor(ref.schemaId).firstOrNull;
    // A sibling view that can write these paths.
    final paths = snapshot.entries.map((e) => e.rule.storage).toSet();
    final sibling = snapshot.schema.views
        .where((v) => v.name != ref.view && v.rules.any((r) => r.access.canWrite && paths.contains(r.storage)))
        .firstOrNull;
    return EmptyState(
      icon: AppIcons.data,
      title: 'No values in this view yet',
      body: CodeText('`${ref.view}` exposes $exposes. Values appear here once ${custodian ?? 'a custodian'} or an operator sets them.'),
      actions: [
        if (sibling != null)
          SecondaryButton(
            label: 'Set a value in ${sibling.name}',
            icon: AppIcons.edit,
            onPressed: () => onEditSibling(ref.schemaId.view(sibling.name)),
          ),
      ],
      command: 'snap get ${ref.path}',
    );
  }

  List<String> custodiansFor(SchemaId id) => [
    for (final s in ctx.snaps)
      if (s.plugs.any((p) => p.view.schemaId == id && p.role == PlugRole.custodian)) s.name,
  ];

  Widget _table(BuildContext context, StagingController staging) {
    final c = context.colors;
    final ref = snapshot.ref;
    final flex = compact ? (8, 72.0, 20, 104.0) : (10, 96.0, 22, 120.0);
    Widget cells(Widget a, Widget b, Widget v, Widget d) => Row(
      children: [
        Expanded(flex: flex.$1, child: a),
        const SizedBox(width: 12),
        SizedBox(width: flex.$2, child: b),
        const SizedBox(width: 12),
        Expanded(flex: flex.$3, child: v),
        const SizedBox(width: 12),
        SizedBox(width: flex.$4, child: d),
      ],
    );

    final head = tableHeaderStyle(context);
    return Semantics(
      label: 'Values in ${context.aliased(ref.path)}',
      container: true,
      child: SectionCard(
        child: MinWidthScroll(
          minWidth: 600,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                child: cells(Text('Key', style: head), Text('Type', style: head), Text('Value', style: head), Text('Access', style: head)),
              ),
              InkWell(
                onTap: () => setState(() => _collapsed = !_collapsed),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.outlineVariant)),
                  ),
                  child: Semantics(
                    button: true,
                    container: true,
                    label: '${_collapsed ? 'Expand' : 'Collapse'} ${ref.view}',
                    excludeSemantics: true,
                    child: Row(
                      children: [
                        Icon(_collapsed ? AppIcons.chevronRight : AppIcons.expand, size: 18, color: c.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Text(ref.view, style: context.text.bodyMedium?.mono),
                        const SizedBox(width: 8),
                        const TypeChip('map'),
                        const SizedBox(width: 8),
                        Text(
                          '${snapshot.entries.length} keys in this view',
                          style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!_collapsed)
                for (final e in snapshot.entries)
                  ListRow(
                    color: e.key == selected ? c.secondaryContainer : null,
                    padding: const EdgeInsets.fromLTRB(42, 8, 16, 8),
                    onTap: () => onSelect(e.key),
                    semanticLabel: '${e.key}, ${e.typeLabel}',
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: cells(
                        _KeyText(text: e.key, query: query, selected: e.key == selected),
                        Align(alignment: Alignment.centerLeft, child: TypeChip(e.typeLabel)),
                        _ValueCell(entry: e, staged: staging.lookup(ref, e.key), custodian: custodiansFor(ref.schemaId).firstOrNull),
                        AccessLabel(e.rule.access),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Key with the search match highlighted in tertiaryContainer.
class _KeyText extends StatelessWidget {
  const _KeyText({required this.text, required this.query, required this.selected});
  final String text;
  final String query;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = context.text.bodyMedium!.mono.copyWith(
      fontWeight: FontWeight.w500,
      color: selected ? c.onSecondaryContainer : c.onSurface,
    );
    final i = query.isEmpty ? -1 : text.toLowerCase().indexOf(query.toLowerCase());
    if (i < 0) return Text(text, style: base);
    final hl = base.copyWith(backgroundColor: c.tertiaryContainer, color: c.onTertiaryContainer);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: text.substring(0, i)),
          TextSpan(text: text.substring(i, i + query.length), style: hl),
          TextSpan(text: text.substring(i + query.length)),
        ],
      ),
    );
  }
}

class _ValueCell extends StatelessWidget {
  const _ValueCell({required this.entry, required this.staged, required this.custodian});
  final ViewEntry entry;
  final StagedValue? staged;
  final String? custodian;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mono = context.text.bodyMedium!.mono;
    final muted = context.text.bodyMedium!.copyWith(fontStyle: FontStyle.italic, color: c.onSurfaceVariant);
    final e = entry;
    final s = staged;
    final parts = <Widget>[];
    String? note;

    if (s != null) {
      parts.addAll([
        Semantics(
          label: 'was ${s.beforeText}',
          excludeSemantics: true,
          child: Text(
            s.beforeText,
            style: mono.copyWith(color: c.onSurfaceVariant, decoration: TextDecoration.lineThrough),
          ),
        ),
        ExcludeSemantics(
          child: Text('→', style: mono.copyWith(color: c.onSurfaceVariant)),
        ),
        Text(s.afterText, style: mono.copyWith(fontWeight: FontWeight.w600)),
        s.isRejected ? const StatusBadge.error('Rejected') : const StatusBadge.info('Pending', icon: AppIcons.edit),
      ]);
      if (s.secret) note = 'Write-only${s.fromChange != null ? ' · rejected, fix before applying' : ''}';
    } else if (e.loadError != null) {
      parts.addAll([Text('Unavailable', style: muted), const EphemeralChip(), const StatusBadge.error('Load failed')]);
      note = e.loadError;
    } else if (e.masked) {
      final why = e.writeOnly ? 'write-only' : 'secret';
      parts.add(Text(e.hasValue ? 'Hidden · $why' : 'Unset · $why', style: muted));
      if (e.secret) parts.add(const SecretChip());
    } else if (!e.hasValue) {
      parts.add(Text('unset', style: muted));
      if (e.ephemeral) parts.add(const EphemeralChip());
    } else {
      parts.add(Text(displayValue(e.node, e.value), style: mono));
      if (e.ephemeral) {
        parts.add(const EphemeralChip());
        note = 'Loaded by ${custodian ?? 'the custodian'} when read';
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: parts),
        if (note != null) ...[const SizedBox(height: 2), Text(note, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant))],
      ],
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.failure, required this.onRetry});
  final HookFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => InlineMessage(
    kind: MessageKind.error,
    title: 'Error · ${failure.snap}’s load-view hook failed',
    body: CodeText(
      '`${failure.hook}` ${failure.message}${failure.requestPath == null ? '' : ' while loading `${failure.requestPath}`'}. '
      'Stored values are shown; ephemeral values are unavailable.',
    ),
    actions: [
      OnContainerButton(label: 'Retry load', icon: AppIcons.retry, onPressed: onRetry),
      CliDisclosure('sudo snap logs ${failure.snap} -n 50'),
    ],
  );
}

/// Other views that map the same storage path: `wifi-state · read`.
List<String> otherViews(ConfdbSchema schema, String view, String storagePath) => [
  for (final (v, r) in schema.viewsUsing(storagePath))
    if (v.name != view) '${v.name} · ${r.access.label}',
];

/// Connected custodian snap of a view, falling back to any custodian of the schema.
String? custodianName(ViewRef ref, List<SnapInfo> snaps) =>
    custodianOf(ref, snaps)?.snap ??
    snaps.expand((s) => s.plugs).where((p) => p.role == PlugRole.custodian && p.view.schemaId == ref.schemaId).firstOrNull?.snap;
