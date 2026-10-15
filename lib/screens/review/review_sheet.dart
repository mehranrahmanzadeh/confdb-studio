import 'package:flutter/material.dart';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/access.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../state/staging_controller.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/account_name.dart';

/// 7.7 Review & apply: modal side sheet over the current screen.
Future<void> showReviewSheet(BuildContext context) {
  final scope = context.scope;
  final messenger = ScaffoldMessenger.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close review',
    barrierColor: context.colors.scrim.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => _ReviewSheet(scope: scope, messenger: messenger),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({required this.scope, required this.messenger});
  final AppScope scope;
  final ScaffoldMessengerState messenger;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  late final Future<(List<ConfdbSchema>, List<SnapInfo>)> _context = _load(widget.scope.repository);
  bool _applying = false;
  Object? _error;

  StagingController get staging => widget.scope.staging;

  static Future<(List<ConfdbSchema>, List<SnapInfo>)> _load(ConfdbRepository repo) async {
    final r = await Future.wait([repo.listSchemas(), repo.listSnaps()]);
    return (r[0] as List<ConfdbSchema>, r[1] as List<SnapInfo>);
  }

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    final repo = widget.scope.repository;
    final app = widget.scope.app;
    final applied = <ConfdbChange>[];
    ConfdbChange? rejected;
    try {
      for (final ref in staging.views) {
        final values = {for (final v in staging.forView(ref)) v.key: v.value};
        final change = await repo.applyValues(ref, values);
        if (change.status == ChangeStatus.done) {
          staging.clearView(ref);
          applied.add(change);
        } else {
          staging.markRejected(change);
          rejected ??= change;
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = e;
        });
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (rejected != null) {
      final key = rejected.values.firstOrNull?.key;
      app.go(DataRoute(view: rejected.view, key: key));
      return;
    }
    if (applied.isNotEmpty) {
      showToast(
        widget.messenger,
        Text(applied.length == 1 ? 'Change #${applied.first.id} applied' : 'Changes ${applied.map((c) => '#${c.id}').join(', ')} applied'),
        actionLabel: 'View',
        onAction: () => app.go(const ActivityRoute()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: c.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(left: Radius.circular(12))),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 580,
          height: double.infinity,
          child: ListenableBuilder(
            listenable: staging,
            builder: (context, _) => FutureBuilder(future: _context, builder: (context, snap) => _content(context, snap.data)),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, (List<ConfdbSchema>, List<SnapInfo>)? data) {
    final c = context.colors;
    final views = staging.views;
    final n = staging.count;
    final blocked = staging.all.any((v) => v.isRejected && v.secret && v.value is String && (v.value as String).isEmpty);

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Review ${plural(n, 'change')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Review ${plural(n, 'change')}', style: context.text.titleLarge),
                      const SizedBox(height: 6),
                      CodeText(
                        views.length == 1
                            ? 'Applied as one transaction through `${views.first.path}`. If a custodian hook rejects it, nothing changes.'
                            : 'Applied as one transaction per view. If a custodian hook rejects one, nothing in that view changes.',
                        style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                        codeColor: c.onSurface,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _applying ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.close, size: 22),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              children: [
                if (n == 0) Text('Nothing is staged.', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                for (final ref in views) ..._viewSection(context, ref, data, showViewName: views.length > 1),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: InlineMessage(
                kind: MessageKind.error,
                title: 'Couldn’t apply',
                body: CodeText('$_error Your staged values are kept.'),
                padding: const EdgeInsets.all(12),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.outlineVariant)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _applying ? null : () => Navigator.of(context).pop(), child: const Text('Back')),
                const SizedBox(width: 8),
                PrimaryButton(
                  label: _applying ? 'Applying…' : 'Apply ${plural(n, 'change')}',
                  icon: AppIcons.check,
                  busy: _applying,
                  onPressed: n == 0 || blocked ? null : _apply,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _viewSection(BuildContext context, ViewRef ref, (List<ConfdbSchema>, List<SnapInfo>)? data, {required bool showViewName}) {
    final c = context.colors;
    final staged = staging.forView(ref);
    final schema = data?.$1.where((s) => s.id == ref.schemaId).firstOrNull;
    final hooks = schema == null ? const <PlannedHook>[] : planWriteHooks(schema, data!.$2, staged.map((v) => v.storagePath).toSet());

    return [
      if (showViewName) ...[AccountPath(ref.path, style: context.text.titleSmall?.mono), const SizedBox(height: 10)],
      Text('Staged changes', style: context.text.titleSmall),
      const SizedBox(height: 10),
      for (final v in staged) ...[
        _StagedCard(value: v, onUnstage: _applying ? null : () => staging.unstage(ref, v.key)),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 10),
      Text('Snaps and hooks that will run', style: context.text.titleSmall),
      const SizedBox(height: 10),
      if (data == null)
        const LinearProgressIndicator()
      else if (hooks.isEmpty)
        Text(
          'No custodian is connected, so no hooks will run and no snap validates these values.',
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        )
      else
        for (var i = 0; i < hooks.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hooks[i].role == PlugRole.custodian ? c.secondaryContainer : c.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: context.text.bodySmall?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: hooks[i].role == PlugRole.custodian ? c.onSecondaryContainer : c.onSurfaceVariant,
                    ),
                  ),
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
                              text: hooks[i].snap,
                              style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const TextSpan(text: ' · '),
                            TextSpan(text: hooks[i].hook, style: context.text.bodyMedium?.mono),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(hooks[i].description, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerLeft,
        child: CliDisclosure(staging.commandFor(ref), label: 'CLI · combined command', initiallyOpen: true),
      ),
      const SizedBox(height: 24),
    ];
  }
}

class _StagedCard extends StatelessWidget {
  const _StagedCard({required this.value, required this.onUnstage});
  final StagedValue value;
  final VoidCallback? onUnstage;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final mono = context.text.bodyMedium!.mono.copyWith(fontSize: 13);
    Widget line(String label, String mark, Color markColor, Color bg, String text, {bool bold = false}) => Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 16,
            child: ExcludeSemantics(
              child: Text(
                mark,
                style: mono.copyWith(fontWeight: FontWeight.w700, color: markColor),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: bold ? mono.copyWith(fontWeight: FontWeight.w600) : mono),
          ),
        ],
      ),
    );
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(value.key, style: context.text.bodyLarge?.mono.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: CodeText(
                  'storage `${value.storagePath}` · ${value.node?.typeLabel ?? 'value'}',
                  style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: onUnstage,
                style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
                child: const Text('Unstage'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              children: [
                line(
                  'Before',
                  '−',
                  c.error,
                  Color.alphaBlend(c.errorContainer.withValues(alpha: 0.5), c.surfaceContainerLowest),
                  value.beforeText,
                ),
                line(
                  'After',
                  '+',
                  s.success,
                  Color.alphaBlend(s.successContainer.withValues(alpha: 0.55), c.surfaceContainerLowest),
                  value.afterText,
                  bold: true,
                ),
              ],
            ),
          ),
          if (value.isRejected) ...[
            const SizedBox(height: 8),
            CodeText(
              'Rejected in #${value.fromChange} by `${value.rejectedBy}`: ${value.rejection}. Fix it in the Data explorer before applying.',
              style: context.text.bodySmall?.copyWith(color: c.error),
            ),
          ],
        ],
      ),
    );
  }
}
