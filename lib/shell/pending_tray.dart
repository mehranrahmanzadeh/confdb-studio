import 'package:flutter/material.dart';

import '../state/staging_controller.dart';
import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import '../util/format.dart';
import '../widgets/app_icons.dart';
import '../widgets/cli_disclosure.dart';
import '../widgets/common.dart';

/// Tray.dc.html: docked at the bottom whenever edits are staged.
class PendingTray extends StatelessWidget {
  const PendingTray({super.key, required this.staging, required this.onReview, required this.onDiscard});

  final StagingController staging;
  final VoidCallback onReview;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final n = staging.count;
    final views = staging.views;
    final summary = [for (final ref in views) '${staging.forView(ref).map((v) => v.trayText).join(' · ')} · via ${ref.path}'].join(' · ');
    final command = views.map(staging.commandFor).join(' && ');

    return Semantics(
      container: true,
      label: 'Pending changes',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: c.surfaceContainerHigh,
          border: Border(top: BorderSide(color: c.outlineVariant)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summaryBlock = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: s.informationContainer, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
                  child: Icon(AppIcons.edit, size: 20, color: s.onInformationContainer),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(plural(n, 'pending change'), style: context.text.titleSmall),
                      Text(summary, style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            );
            final actions = [
              CliDisclosure(command),
              TextButton(onPressed: onDiscard, child: const Text('Discard')),
              PrimaryButton(label: 'Review & apply', icon: AppIcons.check, onPressed: onReview),
            ];
            if (constraints.maxWidth < 900) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  summaryBlock,
                  const SizedBox(height: 12),
                  Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: summaryBlock),
                for (final a in actions) ...[const SizedBox(width: 16), a],
              ],
            );
          },
        ),
      ),
    );
  }
}
