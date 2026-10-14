import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/values.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../state/staging_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/loader.dart';
import '../../widgets/step_icon.dart';

/// 7.11 Change detail (ChangeDetail.dc.html for #1842, -1845 for done).
class ChangeDetailScreen extends StatelessWidget {
  const ChangeDetailScreen({super.key, required this.id});
  final int id;

  @override
  Widget build(BuildContext context) => Loader<ConfdbChange>(
    key: ValueKey(id),
    load: (repo) => repo.getChange(id),
    loading: (context) => PageBody(children: [LoadingRow('Loading change #$id…')]),
    error: (context, e, retry) => PageBody(
      children: [
        const _BackLink(),
        LoadErrorMessage(title: 'Couldn’t load change #$id', error: e, onRetry: retry, command: 'snap change $id'),
      ],
    ),
    builder: (context, change, _) => _Detail(change: change),
  );
}

class _BackLink extends StatelessWidget {
  const _BackLink();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Transform.translate(
      offset: const Offset(-8, 0),
      child: TertiaryButton(label: 'Activity', icon: AppIcons.back, onPressed: () => context.app.go(const ActivityRoute())),
    ),
  );
}

class _Detail extends StatefulWidget {
  const _Detail({required this.change});
  final ConfdbChange change;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  bool _reveal = false;
  bool _copied = false;
  bool _retrying = false;
  Timer? _copyReset;
  late final Set<int> _open = {
    for (var i = 0; i < widget.change.steps.length; i++)
      if (widget.change.steps[i].state == ChangeStepState.failed && widget.change.steps[i].output != null) i,
  };

  ConfdbChange get ch => widget.change;
  bool get failed => ch.status == ChangeStatus.error;
  bool get isSet => ch.kind == 'set-confdb' && ch.view != null;

  @override
  void dispose() {
    _copyReset?.cancel();
    super.dispose();
  }

  /// The command that reproduces (or retries) this change.
  String get _command {
    if (isSet) {
      return snapSetCommand(ch.view!, [for (final v in ch.values) (v.key, v.afterRaw ?? v.after, v.secret)]);
    }
    final code = ch.summary.split('`').elementAtOrNull(1);
    if (ch.kind == 'connect-snap' && code != null) return 'sudo snap connect $code';
    if (ch.kind == 'disconnect-snap' && code != null) return 'sudo snap disconnect $code';
    return 'snap change ${ch.id}';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _command));
    if (!mounted) return;
    setState(() => _copied = true);
    _copyReset?.cancel();
    _copyReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Stages the failed values again, with the rejection attached, and opens
  /// them in the Data explorer so they can be fixed.
  Future<void> _retryWithFix() async {
    final scope = context.scope;
    setState(() => _retrying = true);
    try {
      final snap = await scope.repository.readView(ch.view!);
      for (final v in ch.values) {
        final entry = snap.entries.where((e) => e.key == v.key).firstOrNull;
        scope.staging.stage(
          StagedValue(
            view: ch.view!,
            key: v.key,
            storagePath: v.storagePath,
            node: entry?.node ?? resolveStoragePath(snap.schema.storage, v.storagePath),
            before: v.secret ? null : entry?.value,
            value: v.afterRaw ?? (v.secret ? '' : v.after),
            secret: v.secret,
            fromChange: ch.id,
            rejection: ch.error,
            rejectedBy: ch.rejectedBy,
          ),
        );
      }
      scope.app.go(DataRoute(view: ch.view, key: ch.values.firstOrNull?.key));
    } catch (e) {
      if (!mounted) return;
      setState(() => _retrying = false);
      showConfirmation(context, Text('Couldn’t read ${ch.view!.path}: $e'));
    }
  }

  String get _meta {
    final who = ch.initiator == 'You' ? 'you' : ch.initiator;
    final parts = ['Initiated by $who', dayAndTime(ch.spawnTime)];
    final hooks = ch.steps.where((s) => s.title.contains('-view-') && s.state != ChangeStepState.pending).length;
    if (failed) {
      final n = ch.steps.where((s) => s.state == ChangeStepState.failed).length;
      parts.add('${plural(n, 'task')} failed');
      if (ch.steps.any((s) => s.state == ChangeStepState.rolledBack)) parts.add('rolled back, nothing changed');
    } else if (ch.status == ChangeStatus.done) {
      if (hooks > 0) parts.add('${plural(hooks, 'hook')} ran');
      parts.add(isSet ? 'committed' : 'done');
    } else {
      parts.add(ch.status.label.toLowerCase());
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = context.app;
    final title = Text.rich(
      TextSpan(
        style: context.text.headlineSmall,
        children: [
          TextSpan(text: '#${ch.id} ', style: context.text.headlineSmall?.mono),
          ...CodeText.spans(ch.summary, context.text.headlineSmall!),
        ],
      ),
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TertiaryButton(label: _copied ? 'Copied' : 'Copy CLI', icon: _copied ? AppIcons.check : AppIcons.copy, onPressed: _copy),
        if (isSet && failed) PrimaryButton(label: 'Retry with fix', icon: AppIcons.retry, busy: _retrying, onPressed: _retryWithFix),
        if (isSet && !failed)
          SecondaryButton(
            label: 'Open in Data explorer',
            icon: AppIcons.data,
            onPressed: () => app.go(DataRoute(view: ch.view, key: ch.values.firstOrNull?.key)),
          ),
        if (ch.kind.contains('connect'))
          SecondaryButton(
            label: 'Open in Access',
            icon: AppIcons.access,
            onPressed: () => app.go(AccessRoute(snap: changeSnap)),
          ),
      ],
    );

    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ch.values.isNotEmpty) ...[
          Semantics(header: true, child: Text('Values', style: context.text.titleMedium)),
          const SizedBox(height: 10),
          for (final v in ch.values) ...[_valueRow(context, v), const SizedBox(height: 8)],
          if (ch.values.any((v) => v.secret))
            CodeText(
              'Secrets are masked. The previous value can’t be revealed because ${ch.values.where((v) => v.secret).map((v) => '`${v.key}`').join(', ')} is write-only.',
              style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          const SizedBox(height: 20),
        ],
        Semantics(header: true, child: Text('Timeline', style: context.text.titleMedium)),
        const SizedBox(height: 10),
        Timeline(items: [for (var i = 0; i < ch.steps.length; i++) (_stepIcon(ch.steps[i]), _stepBody(context, i, ch.steps[i]))]),
      ],
    );

    final aside = Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Details', style: context.text.titleSmall),
          const SizedBox(height: 14),
          DetailList(
            labelWidth: 104,
            rows: [
              ('Change', MonoText('${ch.id}')),
              ('Kind', MonoText(ch.kind)),
              if (ch.view != null) ('View', MonoText(ch.view!.path)),
              if (ch.custodian != null) ('Custodian', MonoText(ch.custodian!)),
              if (ch.observers.isNotEmpty) ('Observers', MonoText(ch.observers.join(', '))),
              (
                'Status',
                Text(failed && ch.steps.any((s) => s.state == ChangeStepState.rolledBack) ? 'Error · rolled back' : ch.status.label),
              ),
            ],
          ),
          const SizedBox(height: 14),
          CliDisclosure('snap change ${ch.id}', initiallyOpen: true),
        ],
      ),
    );

    return PageBody(
      gap: 20,
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 40),
      children: [
        const _BackLink(),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [ChangeBadge(ch.status), title],
                  ),
                  const SizedBox(height: 8),
                  Text(_meta, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
            ),
            actions,
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 900) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, const SizedBox(height: 24), aside]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: main),
                const SizedBox(width: 24),
                SizedBox(width: 380, child: aside),
              ],
            );
          },
        ),
      ],
    );
  }

  String? get changeSnap => ch.summary.split('`').elementAtOrNull(1)?.split(':').first;

  Widget _valueRow(BuildContext context, ValueDiff v) {
    final c = context.colors;
    final s = context.status;
    final mono = context.text.bodyMedium!.mono;
    Widget pill(String label, String text, Color bg, {bool bold = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          const SizedBox(width: 6),
          Text(text, style: bold ? mono.copyWith(fontWeight: FontWeight.w600) : mono),
        ],
      ),
    );
    final after = v.secret && _reveal && v.afterRaw != null
        ? (v.afterRaw is String ? v.afterRaw as String : jsonEncode(v.afterRaw))
        : v.after;
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
      child: Wrap(
        spacing: 20,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(v.key, style: context.text.bodyLarge?.mono.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(v.storagePath, style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant)),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              pill('Before', v.before, Color.alphaBlend(c.errorContainer.withValues(alpha: 0.5), c.surfaceContainerLowest)),
              ExcludeSemantics(
                child: Text('→', style: mono.copyWith(color: c.onSurfaceVariant)),
              ),
              pill('After', after, Color.alphaBlend(s.successContainer.withValues(alpha: 0.55), c.surfaceContainerLowest), bold: true),
            ],
          ),
          if (v.secret && v.afterRaw != null)
            Semantics(
              toggled: _reveal,
              child: IconButton(
                tooltip: _reveal ? 'Hide new value' : 'Reveal new value',
                onPressed: () => setState(() => _reveal = !_reveal),
                icon: Icon(_reveal ? AppIcons.eyeOff : AppIcons.eye, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepIcon(ChangeStep s) => switch (s.state) {
    ChangeStepState.user => const StepIcon(tone: StepTone.neutral, icon: AppIcons.user),
    ChangeStepState.passed => const StepIcon(tone: StepTone.passed),
    ChangeStepState.failed => const StepIcon(tone: StepTone.failed),
    ChangeStepState.rolledBack => const StepIcon(tone: StepTone.neutral, icon: AppIcons.undo),
    ChangeStepState.running => const StepIcon(tone: StepTone.running),
    ChangeStepState.pending => const StepIcon(tone: StepTone.pending),
  };

  Widget _stepBody(BuildContext context, int i, ChangeStep s) {
    final c = context.colors;
    final (_, _, labelColor) = StepIcon.colors(context, switch (s.state) {
      ChangeStepState.passed => StepTone.passed,
      ChangeStepState.failed => StepTone.failed,
      ChangeStepState.running => StepTone.running,
      ChangeStepState.pending => StepTone.pending,
      _ => StepTone.neutral,
    });
    final label = switch (s.state) {
      ChangeStepState.user => 'Done',
      ChangeStepState.passed => 'Passed',
      ChangeStepState.failed => 'Failed',
      ChangeStepState.rolledBack => 'Rolled back',
      ChangeStepState.running => 'Running',
      ChangeStepState.pending => 'Pending',
    };
    final meta = s.meta.isEmpty && i == 0
        ? hms(ch.spawnTime)
        : (s.meta.isEmpty ? (ch.readyTime == null ? '' : hms(ch.readyTime!)) : s.meta);
    final out = s.output;
    final open = _open.contains(i);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CodeText(s.title, style: context.text.titleMedium?.copyWith(fontSize: 15, height: 22 / 15)),
              Text(
                label,
                style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: labelColor),
              ),
              if (meta.isNotEmpty) Text(meta, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            ],
          ),
          if (s.description != null) ...[
            const SizedBox(height: 6),
            CodeText(s.description!, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          ],
          if (out != null) ...[
            const SizedBox(height: 6),
            Semantics(
              expanded: open,
              child: TextButton(
                onPressed: () => setState(() => open ? _open.remove(i) : _open.add(i)),
                style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.fromLTRB(6, 0, 10, 0)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(open ? AppIcons.expand : AppIcons.chevronRight, size: 16),
                    const SizedBox(width: 6),
                    Text(open ? 'Hide output' : 'Show output'),
                  ],
                ),
              ),
            ),
            if (open) _OutputPanel(output: out),
          ],
        ],
      ),
    );
  }
}

/// Hook output with stdout/stderr tabs; the non-empty stream first.
class _OutputPanel extends StatefulWidget {
  const _OutputPanel({required this.output});
  final HookOutput output;

  @override
  State<_OutputPanel> createState() => _OutputPanelState();
}

class _OutputPanelState extends State<_OutputPanel> {
  late int _tab = widget.output.stderr.isNotEmpty ? 0 : 1;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final o = widget.output;
    final tabs = [('stderr${o.stderr.isEmpty ? ' (empty)' : ''}', o.stderr), ('stdout${o.stdout.isEmpty ? ' (empty)' : ''}', o.stdout)];
    final order = o.stderr.isNotEmpty ? [0, 1] : [1, 0];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surfaceContainer,
        border: Border.all(color: c.outlineVariant),
        borderRadius: BorderRadius.circular(ConfdbRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.outlineVariant)),
            ),
            child: Row(
              children: [
                for (final t in order)
                  Semantics(
                    selected: _tab == t,
                    child: InkWell(
                      mouseCursor: WidgetStateMouseCursor.clickable,
                      onTap: () => setState(() => _tab = t),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 40),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: _tab == t ? c.onSurface : Colors.transparent, width: 2)),
                        ),
                        child: Text(
                          tabs[t].$1,
                          style: context.text.bodySmall?.copyWith(
                            fontSize: 13,
                            fontWeight: _tab == t ? FontWeight.w600 : FontWeight.w500,
                            color: _tab == t ? c.onSurface : c.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SelectableText(
              tabs[_tab].$2.isEmpty ? '(no output)' : tabs[_tab].$2,
              style: context.text.bodyMedium?.mono.copyWith(fontSize: 13, color: tabs[_tab].$2.isEmpty ? c.onSurfaceVariant : c.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
