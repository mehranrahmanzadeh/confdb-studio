import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/access.dart';
import '../../domain/playground.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';
import '../../widgets/loader.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/step_icon.dart';

class _PlaygroundData {
  const _PlaygroundData(this.draft, this.acknowledged, this.snaps);
  final ConfdbSchema draft;

  /// Whether the schema is acknowledged, so current values can be read.
  final bool acknowledged;
  final List<SnapInfo> snaps;
}

/// 7.8 View playground (Playground.dc.html, Playground-Denied).
class PlaygroundScreen extends StatelessWidget {
  const PlaygroundScreen({super.key, required this.route});
  final PlaygroundRoute route;

  Future<_PlaygroundData> _load(ConfdbRepository repo) async {
    final r = await Future.wait([repo.listDrafts(), repo.listSchemas(), repo.listSnaps()]);
    final drafts = r[0] as List<ConfdbSchema>;
    final schemas = r[1] as List<ConfdbSchema>;
    final base = schemas.where((s) => s.id == route.id).firstOrNull;
    final draft = drafts.where((s) => s.id == route.id).firstOrNull ?? base;
    if (draft == null) throw ConfdbException('No draft or schema ${route.id.path}', kind: ConfdbErrorKind.notFound);
    return _PlaygroundData(draft, base != null, r[2] as List<SnapInfo>);
  }

  @override
  Widget build(BuildContext context) => Loader<_PlaygroundData>(
    key: ValueKey(route.id),
    load: _load,
    reloadOnChange: false,
    loading: (context) => const PageBody(children: [LoadingRow('Loading the draft…')]),
    error: (context, e, retry) => PageBody(
      children: [LoadErrorMessage(title: 'Couldn’t open the playground', error: e, onRetry: retry)],
    ),
    builder: (context, data, _) => _Playground(route: route, data: data),
  );
}

class _Playground extends StatefulWidget {
  const _Playground({required this.route, required this.data});
  final PlaygroundRoute route;
  final _PlaygroundData data;

  @override
  State<_Playground> createState() => _PlaygroundState();
}

class _PlaygroundState extends State<_Playground> {
  late String _view = widget.route.view;
  late final _path = TextEditingController(text: widget.route.path ?? _firstRequest(_view));
  final _value = TextEditingController();
  bool _isSet = false;
  late String? _snap = widget.route.snap ?? _defaultSnap(_view);
  Future<SimResult>? _result;

  ConfdbSchema get draft => widget.data.draft;
  List<SnapInfo> get snaps => widget.data.snaps;

  String _firstRequest(String view) => draft.view(view)?.rules.firstOrNull?.request ?? '';

  /// The view's custodian, else any snap with a plug in this schema.
  String? _defaultSnap(String view) =>
      custodianOf(draft.id.view(view), snaps)?.snap ??
      snaps.where((s) => s.plugs.any((p) => p.view.schemaId == draft.id)).firstOrNull?.name ??
      snaps.firstOrNull?.name;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  @override
  void dispose() {
    _path.dispose();
    _value.dispose();
    super.dispose();
  }

  SimRequest? get _request {
    final snap = snaps.where((s) => s.name == _snap).firstOrNull;
    if (snap == null) return null;
    return SimRequest(draft: draft, view: _view, path: _path.text.trim(), isSet: _isSet, value: _value.text, snap: snap);
  }

  void _run() {
    final req = _request;
    if (req == null) return;
    final repo = context.repo;
    final acknowledged = widget.data.acknowledged;
    setState(() {
      _result = simulate(
        req,
        snaps: snaps,
        readCurrent: (ref) async {
          if (!acknowledged) return null;
          try {
            return await repo.readView(ref);
          } on ConfdbException {
            return null; // the view may only exist in the draft
          }
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final req = _request;
    final view = draft.view(_view);
    final snapInfo = snaps.where((s) => s.name == _snap).firstOrNull;
    final plug = snapInfo?.plugs.where((p) => p.view == draft.id.view(_view)).firstOrNull;
    final snapHelp = snapInfo == null
        ? 'Pick a snap'
        : plug != null
        ? '${plug.role.label} · plug ${plug.plug} ${plug.state.isConnected ? 'connected' : 'not connected'}'
        : '${snapInfo.isCustodian ? 'Custodian' : 'Observer'} · ${snapInfo.plugs.isEmpty ? 'no confdb plugs' : 'plug ${snapInfo.plugs.map((p) => p.plug).join(', ')} ${snapInfo.plugs.every((p) => p.state.isConnected) ? 'connected' : 'not connected'}'}';

    final form = Panel(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedSelect<String>(
            label: 'View',
            helper: view == null
                ? null
                : '${draft.isDraft ? 'Draft' : 'Revision ${draft.revision}'} · ${view.access.label} · ${plural(view.rules.length, 'rule')}',
            items: [
              for (final v in draft.views)
                (v.name, Text(draft.id.view(v.name).path, style: context.text.bodyLarge?.mono.copyWith(fontSize: 15))),
            ],
            onSelected: (v) => setState(() {
              _view = v;
              _path.text = _firstRequest(v);
            }),
            child: Text(draft.id.view(_view).path),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _path,
            style: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
            onSubmitted: (_) => _run(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Request path',
              helperText: 'A path in the view’s namespace, as a snap would request it',
              prefixText: '$_view › ',
              prefixStyle: context.text.bodyLarge?.mono.copyWith(fontSize: 15, color: context.colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          Text('Operation', style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Get')),
              ButtonSegment(value: true, label: Text('Set (dry run)')),
            ],
            selected: {_isSet},
            onSelectionChanged: (s) => setState(() => _isSet = s.first),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _value,
            enabled: _isSet,
            style: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Value',
              helperText: _isSet
                  ? 'Checked against the draft’s storage schema; nothing is written'
                  : 'Disabled · only used by Set (dry run)',
            ),
          ),
          const SizedBox(height: 20),
          OutlinedSelect<String>(
            label: 'Simulate as snap',
            helper: snapHelp,
            items: [for (final s in snaps) (s.name, Text(s.name, style: context.text.bodyLarge?.mono.copyWith(fontSize: 15)))],
            onSelected: (s) => setState(() => _snap = s),
            child: Text(_snap ?? 'No snaps with confdb plugs'),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: PrimaryButton(label: 'Run simulation', icon: AppIcons.play, onPressed: req == null ? null : _run),
          ),
          const SizedBox(height: 8),
          if (req != null)
            Align(
              alignment: Alignment.centerLeft,
              child: CliDisclosure(snapctlCommand(req), label: 'CLI · inside the snap', initiallyOpen: true),
            ),
        ],
      ),
    );

    final results = FutureBuilder<SimResult>(
      future: _result,
      builder: (context, snap) {
        final r = snap.data;
        if (r == null) {
          return snap.connectionState == ConnectionState.waiting ? const LinearProgressIndicator() : const SizedBox.shrink();
        }
        return _Resolution(
          result: r,
          onConnect: (p) => app.go(AccessRoute(snap: p.snap)),
        );
      },
    );

    return PageBody(
      gap: 20,
      children: [
        PageHeader(
          title: 'View playground',
          subtitle: const Text('Simulate how snapd resolves a request through a view of the draft. Nothing is written and no hooks run.'),
          trailing: TertiaryButton(
            label: 'Back to schema editor',
            icon: AppIcons.back,
            onPressed: () => app.go(SchemaEditorRoute(draft.id, view: _view)),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 900) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [form, const SizedBox(height: 24), results]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 420, child: form),
                const SizedBox(width: 24),
                Expanded(child: results),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Resolution extends StatelessWidget {
  const _Resolution({required this.result, required this.onConnect});
  final SimResult result;
  final ValueChanged<ConfdbPlug> onConnect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(header: true, child: Text('Resolution', style: context.text.titleLarge)),
            result.allowed ? const StatusBadge.success('Allowed') : StatusBadge.error('Denied at step ${result.deniedAt}'),
          ],
        ),
        const SizedBox(height: 16),
        CodeText(
          result.summary,
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          codeColor: c.onSurface,
        ),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Timeline(
            iconColumnWidth: 40,
            items: [for (var i = 0; i < result.steps.length; i++) _step(context, i + 1, result.steps[i])],
          ),
        ),
      ],
    );
  }

  (Widget, Widget) _step(BuildContext context, int n, SimStep s) {
    final c = context.colors;
    final (tone, kind) = switch (s.state) {
      SimState.passed => (StepTone.passed, StatusKind.success),
      SimState.failed => (StepTone.failed, StatusKind.error),
      SimState.skipped => (StepTone.neutral, StatusKind.neutral),
      SimState.info => (StepTone.info, StatusKind.info),
    };
    final fix = s.fixConnect;
    final body = Opacity(
      opacity: s.state == SimState.skipped ? 0.6 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('$n. ${s.title}', style: context.text.titleMedium),
                StatusBadge(kind: kind, label: s.statusLabel, icon: s.state == SimState.info ? AppIcons.hook : null),
              ],
            ),
            if (s.code != null && s.code!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: c.surfaceContainer, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
                child: SelectableText(s.code!, style: context.text.bodyMedium?.mono.copyWith(fontSize: 13)),
              ),
            ],
            const SizedBox(height: 8),
            CodeText(s.text, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
            if (fix != null) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final sameView = s.code?.endsWith(fix.view.path) ?? false;
                  return InlineMessage(
                    kind: MessageKind.error,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    title: 'Plug ${fix.plug} is not connected',
                    body: CodeText(
                      sameView
                          ? 'Connect it to let `${fix.snap}` reach this view.'
                          : '`${fix.plug}` points at `${fix.view.path}`, which doesn’t expose this path. Connecting it won’t help here; add a plug for this view to `${fix.snap}`.',
                    ),
                    actions: [
                      OnContainerButton(
                        label: sameView ? 'Connect plug' : 'Open in Access',
                        icon: sameView ? AppIcons.link : AppIcons.access,
                        onPressed: () => onConnect(fix),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
    final icon = switch (s.state) {
      SimState.info => const StepIcon(tone: StepTone.info),
      SimState.skipped => const StepIcon(tone: StepTone.neutral),
      _ => StepIcon(tone: tone),
    };
    return (icon, body);
  }
}
