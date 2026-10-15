import 'package:flutter/material.dart';

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
import '../../widgets/status_badge.dart';
import '../../widgets/step_icon.dart';
import 'add_plug_guide.dart';
import '../../state/account_names.dart';

/// 7.8 View playground (Playground.dc.html, Playground-Denied): the schema
/// editor's step between editing and signing. Shown below the editor header.
class PlaygroundPanel extends StatefulWidget {
  const PlaygroundPanel({super.key, required this.draft, required this.snaps, required this.route, required this.onView});
  final ConfdbSchema draft;
  final List<SnapInfo> snaps;
  final PlaygroundRoute route;

  /// The selected view changed, so the route can follow.
  final ValueChanged<String> onView;

  @override
  State<PlaygroundPanel> createState() => _PlaygroundState();
}

class _PlaygroundState extends State<PlaygroundPanel> {
  late String _view = widget.route.view;
  late final _path = TextEditingController(text: widget.route.path ?? _firstRequest(_view));
  final _value = TextEditingController();
  bool _isSet = false;

  /// Hooks and services run as root (admin access); apps started by a user don't.
  bool _asRoot = false;
  late String? _snap = widget.route.snap ?? _defaultSnap(_view);
  SimResult? _result;

  /// The request [_result] answers.
  SimRequest? _ran;

  ConfdbSchema get draft => widget.draft;
  List<SnapInfo> get snaps => widget.snaps;

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
    return SimRequest(draft: draft, view: _view, path: _path.text.trim(), isSet: _isSet, value: _value.text, snap: snap, asRoot: _asRoot);
  }

  void _run() {
    final req = _request;
    if (req == null) return;
    setState(() {
      _ran = req;
      _result = simulate(req, snaps: snaps);
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
        : 'No plug for this view';

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
                (v.name, Text(context.aliased(draft.id.view(v.name).path), style: context.text.bodyLarge?.mono.copyWith(fontSize: 15))),
            ],
            onSelected: (v) {
              setState(() {
                _view = v;
                _path.text = _firstRequest(v);
              });
              widget.onView(v);
            },
            child: Text(context.aliased(draft.id.view(_view).path)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _path,
            style: context.text.bodyLarge?.mono.copyWith(fontSize: 15),
            onSubmitted: (_) => _run(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Request path',
              helperText: 'As a snap would request it; a prefix of a rule’s request reads everything below it',
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
          Text('Runs as', style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('App run by a user')),
              ButtonSegment(value: true, label: Text('Hook or service')),
            ],
            selected: {_asRoot},
            onSelectionChanged: (s) => setState(() => _asRoot = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _asRoot
                ? 'Root: snapd grants admin access, so secrets can be read.'
                : 'Not root: snapd grants unprivileged access, so secrets can’t be read.',
            style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
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

    final result = _result;
    final results = result == null
        ? const SizedBox.shrink()
        : _Resolution(
            result: result,
            onConnect: (p) => app.go(AccessRoute(snap: p.snap)),
            onAddPlug: () {
              final ran = _ran;
              if (ran != null) showAddPlugGuide(context, snap: ran.snap.name, view: ran.ref);
            },
          );

    return PageBody(
      gap: 20,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Text(
          'Try the draft as snaps would use it before you sign. Simulates how snapd resolves a request through a view; nothing is written and no hooks run. Results don’t block signing.',
          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
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
  const _Resolution({required this.result, required this.onConnect, required this.onAddPlug});
  final SimResult result;
  final ValueChanged<ConfdbPlug> onConnect;
  final VoidCallback onAddPlug;

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
            if (!result.allowed)
              // The playground is for trying things out: a denial is a warning, not an error.
              StatusBadge.warning('Denied at step ${result.deniedAt}')
            else if (result.hasWarnings)
              StatusBadge.warning(result.steps.first.state == SimState.warning ? 'Allowed once connected' : 'Allowed with warnings')
            else
              const StatusBadge.success('Allowed'),
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
      SimState.failed => (StepTone.warning, StatusKind.warning),
      SimState.warning => (StepTone.warning, StatusKind.warning),
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
              InlineMessage(
                kind: MessageKind.warning,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                title: 'Plug ${fix.plug} is not connected',
                body: CodeText('Connect it to let `${fix.snap}` reach this view.'),
                actions: [OnContainerButton(label: 'Connect plug', icon: AppIcons.link, onPressed: () => onConnect(fix))],
              ),
            ],
            if (s.missingPlug) ...[
              const SizedBox(height: 8),
              InlineMessage(
                kind: MessageKind.warning,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                title: 'No plug for this view',
                body: const Text('Add a confdb plug for this view to the snap, then connect it.'),
                actions: [OnContainerButton(label: 'More info', icon: AppIcons.help, onPressed: onAddPlug)],
              ),
            ],
          ],
        ),
      ),
    );
    final icon = switch (s.state) {
      SimState.info => const StepIcon(tone: StepTone.info),
      SimState.skipped => const StepIcon(tone: StepTone.neutral),
      SimState.failed => StepIcon(tone: tone, icon: AppIcons.close),
      _ => StepIcon(tone: tone),
    };
    return (icon, body);
  }
}
