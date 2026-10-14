import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';

enum StatusKind { success, warning, error, info, neutral, secondary, running }

/// Badge.dc.html: status is always icon + label, never color alone.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.kind, required this.label, this.icon});

  const StatusBadge.success(this.label, {super.key, this.icon}) : kind = StatusKind.success;
  const StatusBadge.warning(this.label, {super.key, this.icon}) : kind = StatusKind.warning;
  const StatusBadge.error(this.label, {super.key, this.icon}) : kind = StatusKind.error;
  const StatusBadge.info(this.label, {super.key, this.icon}) : kind = StatusKind.info;
  const StatusBadge.neutral(this.label, {super.key, this.icon}) : kind = StatusKind.neutral;
  const StatusBadge.running(this.label, {super.key}) : kind = StatusKind.running, icon = null;

  final StatusKind kind;
  final String label;

  /// Overrides the kind's default glyph (the design's `glyph` prop).
  final IconData? icon;

  static (Color bg, Color fg, IconData icon) colorsFor(BuildContext context, StatusKind kind) {
    final c = context.colors;
    final s = context.status;
    return switch (kind) {
      StatusKind.success => (s.successContainer, s.onSuccessContainer, AppIcons.ok),
      StatusKind.warning => (s.warningContainer, s.onWarningContainer, AppIcons.warning),
      StatusKind.error => (c.errorContainer, c.onErrorContainer, AppIcons.error),
      StatusKind.info => (s.informationContainer, s.onInformationContainer, AppIcons.info),
      StatusKind.neutral => (c.surfaceContainerHigh, c.onSurfaceVariant, AppIcons.neutral),
      StatusKind.secondary || StatusKind.running => (c.secondaryContainer, c.onSecondaryContainer, AppIcons.neutral),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, defaultIcon) = colorsFor(context, kind);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 24),
        padding: const EdgeInsets.fromLTRB(6, 2, 10, 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == StatusKind.running)
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg, backgroundColor: fg.withValues(alpha: 0.25)),
              )
            else
              Icon(icon ?? defaultIcon, size: 16, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: context.text.labelMedium?.copyWith(color: fg, letterSpacing: 0.2),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
