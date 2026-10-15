import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/access.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';
import '../../widgets/loader.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/step_icon.dart';
import '../../widgets/account_name.dart';
import '../../state/account_names.dart';

class _AccessData {
  const _AccessData(this.schemas, this.snaps);
  final List<ConfdbSchema> schemas;
  final List<SnapInfo> snaps;
}

Future<_AccessData> _load(ConfdbRepository repo) async {
  final r = await Future.wait([repo.listSchemas(), repo.listSnaps()]);
  return _AccessData(r[0] as List<ConfdbSchema>, r[1] as List<SnapInfo>);
}

/// 7.9 Access (Access.dc.html, Access-Pass, Access-Disconnect).
class AccessScreen extends StatelessWidget {
  const AccessScreen({super.key, required this.route});
  final AccessRoute route;

  @override
  Widget build(BuildContext context) => Loader<_AccessData>(
    load: _load,
    loading: (context) => const PageBody(
      children: [
        _Header(),
        TableSkeleton(message: 'Loading connections from snapd…', columns: [2, 2, 2, 2, 2], rows: [0.6, 0.5, 0.7, 0.4]),
      ],
    ),
    error: (context, e, retry) => PageBody(
      children: [
        const _Header(),
        LoadErrorMessage(title: 'Couldn’t load connections', error: e, onRetry: retry, command: 'snap connections --all'),
      ],
    ),
    builder: (context, data, _) => _AccessBody(route: route, data: data),
  );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const PageHeader(
    title: 'Access',
    subtitle: Text('Which snaps reach which views through confdb plugs. Flip a switch to connect or disconnect a plug.'),
  );
}

class _AccessBody extends StatefulWidget {
  const _AccessBody({required this.route, required this.data});
  final AccessRoute route;
  final _AccessData data;

  @override
  State<_AccessBody> createState() => _AccessBodyState();
}

class _AccessBodyState extends State<_AccessBody> {
  final _busy = <String>{};
  late final _path = TextEditingController(text: widget.route.whyPath ?? _defaultPath(_selected));
  Future<AccessDiagnosis>? _diagnosis;
  String? _checkedSnap;

  List<SnapInfo> get snaps => widget.data.snaps;
  List<ConfdbSchema> get schemas => widget.data.schemas;

  /// The route's snap, else the first one with an unconnected plug.
  SnapInfo? get _selected =>
      snaps.where((s) => s.name == widget.route.snap).firstOrNull ??
      snaps.where((s) => s.plugs.any((p) => !p.state.isConnected)).firstOrNull ??
      snaps.firstOrNull;

  /// First storage path a snap's views expose (e.g. `proxy.http`).
  String _defaultPath(SnapInfo? snap) {
    for (final p in snap?.plugs ?? const <ConfdbPlug>[]) {
      final rule = schemas.where((s) => s.id == p.view.schemaId).firstOrNull?.view(p.view.view)?.rules.firstOrNull;
      if (rule != null) return rule.storage;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _check();
    // Pin the default selection so it doesn't move when plugs connect.
    final snap = _selected;
    if (widget.route.snap == null && snap != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.app.replace(AccessRoute(snap: snap.name, whyPath: widget.route.whyPath));
      });
    }
  }

  @override
  void didUpdateWidget(_AccessBody old) {
    super.didUpdateWidget(old);
    if (old.route.snap != widget.route.snap && _checkedSnap != _selected?.name) {
      _path.text = _defaultPath(_selected);
      _check();
    } else if (old.data != widget.data) {
      _check();
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _check() {
    final snap = _selected;
    if (snap == null || _path.text.trim().isEmpty) {
      setState(() => _diagnosis = null);
      return;
    }
    final repo = context.repo;
    _checkedSnap = snap.name;
    setState(() {
      _diagnosis = diagnoseAccess(snap: snap, storagePath: _path.text.trim(), schemas: schemas, readView: repo.readView);
    });
  }

  void _select(String snap) => context.app.replace(AccessRoute(snap: snap));

  Future<void> _connect(ConfdbPlug plug) async {
    final scope = context.scope;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(plug.id));
    try {
      final change = await scope.repository.connect(plug);
      showToast(messenger, CodeText('Connected `${plug.id}` · change #${change.id}'));
    } catch (e) {
      if (mounted) showConfirmation(context, Text('Couldn’t connect ${plug.id}: $e'));
    } finally {
      if (mounted) setState(() => _busy.remove(plug.id));
    }
  }

  Future<void> _disconnect(ConfdbPlug plug) async {
    final scope = context.scope;
    final messenger = ScaffoldMessenger.of(context);
    final schema = schemas.where((s) => s.id == plug.view.schemaId).firstOrNull;
    final rules = schema?.view(plug.view.view)?.rules ?? const <ViewRule>[];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _DisconnectDialog(plug: plug, rules: rules, schema: schema),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy.add(plug.id));
    try {
      final change = await scope.repository.disconnect(plug);
      showToast(messenger, CodeText('Disconnected `${plug.id}` · change #${change.id}'));
    } catch (e) {
      if (mounted) showConfirmation(context, Text('Couldn’t disconnect ${plug.id}: $e'));
    } finally {
      if (mounted) setState(() => _busy.remove(plug.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(),
        const SizedBox(height: 16),
        _Matrix(
          schemas: schemas.where((s) => !s.builtIn).toList(),
          snaps: snaps,
          selected: selected?.name,
          busy: _busy,
          onSelect: _select,
          onToggle: (plug, on) => on ? _connect(plug) : _disconnect(plug),
        ),
        const SizedBox(height: 16),
        _WhyCheck(
          snaps: snaps,
          snap: selected,
          path: _path,
          diagnosis: _diagnosis,
          busy: _busy,
          onSnap: (s) {
            _select(s);
          },
          onCheck: _check,
          onConnect: _connect,
        ),
      ],
    );
    final aside = selected == null
        ? null
        : _SnapPanel(snap: selected, schemas: schemas, busy: _busy, onConnect: _connect, onDisconnect: _disconnect);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (aside == null) return main;
          if (constraints.maxWidth < 1000) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, const SizedBox(height: 20), aside]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: main),
              const SizedBox(width: 20),
              SizedBox(width: 340, child: aside),
            ],
          );
        },
      ),
    );
  }
}

class _Matrix extends StatelessWidget {
  const _Matrix({
    required this.schemas,
    required this.snaps,
    required this.selected,
    required this.busy,
    required this.onSelect,
    required this.onToggle,
  });
  final List<ConfdbSchema> schemas;
  final List<SnapInfo> snaps;
  final String? selected;
  final Set<String> busy;
  final ValueChanged<String> onSelect;
  final void Function(ConfdbPlug plug, bool on) onToggle;

  static const _snapCol = 176.0;
  static const _cellMin = 128.0;

  /// Puts a rule on the left of every schema group but the first, so a
  /// schema's views read as one block in the header and in every row.
  Widget _groups(BuildContext context, List<Widget> Function(ConfdbSchema s) build) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < schemas.length; i++)
          Expanded(
            flex: schemas[i].views.length,
            child: Container(
              decoration: BoxDecoration(
                border: i == 0 ? null : Border(left: BorderSide(color: c.outlineVariant)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: build(schemas[i])),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final views = [
      for (final s in schemas)
        for (final v in s.views) s.id.view(v.name),
    ];
    final minWidth = _snapCol + views.length * _cellMin + 2;
    final label = context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: c.onSurfaceVariant);

    final header = Container(
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _snapCol,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text('Snap', style: label),
                ),
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: c.outlineVariant)),
                ),
                child: _groups(
                  context,
                  (schema) => [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: AccountPath(
                        schema.id.path,
                        style: context.text.labelLarge?.mono.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        for (final v in schema.views)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
                              child: Text(
                                v.name,
                                textAlign: TextAlign.center,
                                style: context.text.labelMedium?.mono.copyWith(color: c.onSurfaceVariant),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      label: 'Snap access by view',
      container: true,
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MinWidthScroll(
              minWidth: minWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  for (var i = 0; i < snaps.length; i++) _row(context, snaps[i], first: i == 0),
                ],
              ),
            ),
            // Outside the scroll, so it wraps to the window.
            const _Legend(),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SnapInfo snap, {required bool first}) {
    final c = context.colors;
    final s = context.status;
    final isSelected = snap.name == selected;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    return ListRow(
      first: first,
      color: isSelected ? Color.alphaBlend(c.secondaryContainer.withValues(alpha: 0.35), c.surfaceContainerLowest) : null,
      padding: EdgeInsets.zero,
      onTap: () => onSelect(snap.name),
      semanticLabel: 'Select ${snap.name}',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The selected row's accent.
            Container(width: 3, color: isSelected ? c.primary : null),
            SizedBox(
              width: _snapCol - 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      snap.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: snap.publisherSigned
                          ? 'Publisher-signed by ${snap.publisher}'
                          : 'Not publisher-signed · ${snap.installNote ?? 'local install'}',
                      child: Row(
                        children: [
                          Icon(
                            snap.publisherSigned ? AppIcons.verified : AppIcons.upload,
                            size: 14,
                            color: snap.publisherSigned ? s.success : c.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              snap.publisherSigned ? snap.publisher : 'Local install',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: c.outlineVariant)),
                ),
                child: _groups(
                  context,
                  (schema) => [
                    Expanded(
                      child: Row(children: [for (final v in schema.views) Expanded(child: _cell(context, snap, schema.id.view(v.name)))]),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, SnapInfo snap, ViewRef view) {
    final c = context.colors;
    final s = context.status;
    final plug = snap.plugs.where((p) => p.view == view).firstOrNull;
    if (plug == null) {
      return Semantics(
        label: 'No plug',
        excludeSemantics: true,
        child: Tooltip(
          message: '${snap.name} has no plug for ${context.aliased(view.path)}',
          child: Center(
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: c.outlineVariant, shape: BoxShape.circle),
            ),
          ),
        ),
      );
    }
    final on = plug.state.isConnected;
    final isBusy = busy.contains(plug.id);
    final custodian = plug.role == PlugRole.custodian;
    final fg = on ? c.onSurfaceVariant : s.warning;
    return Tooltip(
      message: '${plug.id} · ${plug.role.label} · ${plug.state.label}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                _CellSwitch(
                  value: on,
                  label: '${on ? 'Disconnect' : 'Connect'} ${plug.id}',
                  onChanged: isBusy ? null : (v) => onToggle(plug, v),
                ),
                if (isBusy)
                  const Positioned(right: -16, child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(on ? (custodian ? AppIcons.shield : AppIcons.eye) : AppIcons.warning, size: 13, color: fg),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    on ? plug.role.label : plug.state.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelMedium?.copyWith(color: fg, fontWeight: on ? FontWeight.w500 : FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the marks in the matrix mean.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final style = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    Widget item(Widget mark, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 6),
        Text(text, style: style),
      ],
    );
    Icon icon(IconData i, [Color? color]) => Icon(i, size: 14, color: color ?? c.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        border: Border(top: BorderSide(color: c.outlineVariant)),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 6,
        children: [
          item(icon(AppIcons.shield), 'Custodian: owns the view, runs its hooks'),
          item(icon(AppIcons.eye), 'Observer: reads and writes through it'),
          item(icon(AppIcons.warning, s.warning), 'Plug not connected'),
          item(
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: c.outlineVariant, shape: BoxShape.circle),
            ),
            'No plug',
          ),
        ],
      ),
    );
  }
}

class _WhyCheck extends StatelessWidget {
  const _WhyCheck({
    required this.snaps,
    required this.snap,
    required this.path,
    required this.diagnosis,
    required this.busy,
    required this.onSnap,
    required this.onCheck,
    required this.onConnect,
  });

  final List<SnapInfo> snaps;
  final SnapInfo? snap;
  final TextEditingController path;
  final Future<AccessDiagnosis>? diagnosis;
  final Set<String> busy;
  final ValueChanged<String> onSnap;
  final VoidCallback onCheck;
  final ValueChanged<ConfdbPlug> onConnect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Panel(
      child: FutureBuilder<AccessDiagnosis>(
        future: diagnosis,
        builder: (context, result) {
          final d = result.data;
          final running = result.connectionState == ConnectionState.waiting;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Semantics(
                    header: true,
                    child: Text('Why can’t this snap see a value?', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (running)
                    const StatusBadge.running('Checking…')
                  else if (d != null)
                    d.ok
                        ? StatusBadge.success('${d.snap} can read ${d.storagePath}')
                        : StatusBadge.error('Stops at step ${d.failedStep}: ${d.reason}'),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: [
                  SizedBox(
                    width: 220,
                    child: OutlinedSelect<String>(
                      label: 'Snap',
                      minHeight: 48,
                      items: [for (final s in snaps) (s.name, Text(s.name, style: context.text.bodyMedium?.mono))],
                      onSelected: onSnap,
                      child: Text(snap?.name ?? 'Pick a snap', style: context.text.bodyMedium?.mono),
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: TextField(
                      controller: path,
                      style: context.text.bodyMedium?.mono,
                      onSubmitted: (_) => onCheck(),
                      decoration: const InputDecoration(
                        labelText: 'Storage path',
                        helperText: 'e.g. proxy.http',
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: SecondaryButton(label: 'Check again', icon: AppIcons.retry, busy: running, onPressed: onCheck),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (d != null)
                for (var i = 0; i < d.checks.length; i++) _step(context, i + 1, d.checks[i])
              else if (!running)
                Text('Pick a snap and a storage path to check.', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }

  Widget _step(BuildContext context, int n, AccessCheck k) {
    final c = context.colors;
    final tone = switch (k.state) {
      CheckState.passed => StepTone.passed,
      CheckState.failed => StepTone.failed,
      CheckState.skipped => StepTone.neutral,
    };
    final (_, _, labelColor) = StepIcon.colors(context, tone);
    final label = switch (k.state) {
      CheckState.passed => 'Passed',
      CheckState.failed => 'Failed',
      CheckState.skipped => 'Not checked',
    };
    final fix = k.fixConnect;
    return Opacity(
      opacity: k.state == CheckState.skipped ? 0.62 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StepIcon(tone: tone, size: 28, radius: 14),
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
                          text: '$n. ${k.title}  ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: '$label  ',
                          style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: labelColor),
                        ),
                        ...CodeText.spans(context.aliased(k.text), context.text.bodyMedium!.copyWith(color: c.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (fix != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PrimaryButton(
                          label: 'Connect ${fix.plug}',
                          icon: AppIcons.link,
                          busy: busy.contains(fix.id),
                          onPressed: () => onConnect(fix),
                        ),
                        CliDisclosure('sudo snap connect ${fix.id}'),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapPanel extends StatelessWidget {
  const _SnapPanel({required this.snap, required this.schemas, required this.busy, required this.onConnect, required this.onDisconnect});
  final SnapInfo snap;
  final List<ConfdbSchema> schemas;
  final Set<String> busy;
  final ValueChanged<ConfdbPlug> onConnect;
  final ValueChanged<ConfdbPlug> onDisconnect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isCustodian = snap.isCustodian;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(AppIcons.snap, size: 22, color: c.onSurfaceVariant),
              Semantics(header: true, child: Text(snap.name, style: context.text.titleLarge?.mono.copyWith(fontSize: 20))),
              isCustodian
                  ? const StatusBadge.neutral('Custodian', icon: AppIcons.shield)
                  : const StatusBadge.neutral('Observer', icon: AppIcons.eye),
            ],
          ),
          const SizedBox(height: 16),
          DetailList(
            labelWidth: 120,
            rows: [
              ('Publisher', MonoText(snap.publisher)),
              ('Publisher-signed', Text(snap.publisherSigned ? 'Yes' : 'No${snap.installNote == null ? '' : ' · ${snap.installNote}'}')),
              ('Revision', MonoText(snap.revision)),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          Text('Plugs', style: context.text.titleSmall),
          const SizedBox(height: 8),
          for (final p in snap.plugs) ...[
            SectionCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.plug, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  Text(
                    '→ ${context.aliased(p.view.path)} · ${schemas.where((s) => s.id == p.view.schemaId).firstOrNull?.view(p.view.view)?.access.label ?? 'unknown view'}',
                    style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      p.state.isConnected
                          ? StatusBadge.success(p.state.label, icon: AppIcons.link)
                          : StatusBadge.warning(p.state.label, icon: AppIcons.unlink),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: busy.contains(p.id) ? null : () => p.state.isConnected ? onDisconnect(p) : onConnect(p),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: Text(p.state.isConnected ? 'Disconnect' : 'Connect'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Text('Declared hooks', style: context.text.titleSmall),
          const SizedBox(height: 8),
          if (snap.hooks.isEmpty) Text('Not reported by this backend', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          for (final h in snap.hooks)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(
                children: [
                  Expanded(child: Text(h.name, style: context.text.bodySmall?.mono.copyWith(fontSize: 13))),
                  h.implemented ? const StatusBadge.success('Implemented') : const StatusBadge.warning('Missing'),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            isCustodian
                ? 'Custodians validate writes in change-view hooks and persist them in save-view hooks.'
                : 'Observers don’t run change-view, save-view, load-view or query-view hooks.',
            style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: CliDisclosure('snap connections ${snap.name}')),
        ],
      ),
    );
  }
}

/// Access-Disconnect.dc.html: a decision, so an AlertDialog.
class _DisconnectDialog extends StatelessWidget {
  const _DisconnectDialog({required this.plug, required this.rules, required this.schema});
  final ConfdbPlug plug;
  final List<ViewRule> rules;
  final ConfdbSchema? schema;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final canWrite = rules.any((r) => r.access.canWrite);
    final canRead = rules.any((r) => r.access.canRead);
    final what = canRead && canWrite ? 'read and write' : (canWrite ? 'write' : 'read');
    final hooks = plug.role == PlugRole.observer
        ? 'Its `observe-view-${plug.plug}` hook stops running. You can reconnect later.'
        : 'Its `change-view-${plug.plug}` and `save-view-${plug.plug}` hooks stop running, so writes through this view are no longer validated. You can reconnect later.';
    return AlertDialog(
      backgroundColor: c.surfaceContainerHigh,
      icon: Icon(AppIcons.unlink, color: c.secondary),
      title: CodeText('Disconnect `${plug.id}`?', style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w400), maxLines: 3),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 472),
        child: DefaultTextStyle.merge(
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${plug.snap} will lose $what access to ${rules.length == 1 ? 'this value' : 'these values'}:'),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in rules)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(
                          TextSpan(
                            style: context.text.bodySmall?.mono.copyWith(fontSize: 13, color: c.onSurface),
                            children: [
                              TextSpan(text: r.request),
                              TextSpan(
                                text:
                                    ' · ${r.storage}${resolveStoragePath(schema?.storage ?? const StorageNode.root([]), r.storage)?.ephemeral == true ? ' (ephemeral)' : ''}',
                                style: TextStyle(color: c.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              CodeText(hooks),
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: CliDisclosure('sudo snap disconnect ${plug.id}')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: c.error,
            foregroundColor: c.onError,
            padding: const EdgeInsets.fromLTRB(16, 0, 24, 0),
          ),
          icon: const Icon(AppIcons.unlink, size: 18),
          label: Text('Disconnect and revoke ${plural(rules.length, 'value')}'),
        ),
      ],
    );
  }
}

/// ComponentSheet access cell: a 40×24 switch with a 44×40 hit target.
class _CellSwitch extends StatelessWidget {
  const _CellSwitch({required this.value, required this.label, required this.onChanged});
  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    toggled: value,
    enabled: onChanged != null,
    excludeSemantics: true,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: InkResponse(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      radius: 24,
      child: SizedBox(
        width: 44,
        height: 40,
        child: Center(
          child: Transform.scale(
            scale: 0.77,
            child: ExcludeFocus(
              child: Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ),
          ),
        ),
      ),
    ),
  );
}
