import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_icons.dart';

enum StepTone { passed, failed, pending, running, neutral, info }

/// ComponentSheet "Timeline step": 32px tile with an icon or spinner.
class StepIcon extends StatelessWidget {
  const StepIcon({super.key, required this.tone, this.icon, this.size = 32, this.radius = 12});

  final StepTone tone;

  /// Overrides the tone's default icon (rolled back, user, hook…).
  final IconData? icon;
  final double size;
  final double radius;

  /// (background, foreground, label color) for a tone.
  static (Color, Color, Color) colors(BuildContext context, StepTone tone) {
    final c = context.colors;
    final s = context.status;
    return switch (tone) {
      StepTone.passed => (s.successContainer, s.onSuccessContainer, s.success),
      StepTone.failed => (c.errorContainer, c.onErrorContainer, c.error),
      StepTone.pending => (Colors.transparent, c.onSurfaceVariant, c.onSurfaceVariant),
      StepTone.running => (c.secondaryContainer, c.onSecondaryContainer, c.onSecondaryContainer),
      StepTone.neutral => (c.surfaceContainerHigh, c.onSurfaceVariant, c.onSurfaceVariant),
      StepTone.info => (s.informationContainer, s.onInformationContainer, s.information),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, _) = colors(context, tone);
    final defaultIcon = switch (tone) {
      StepTone.passed => AppIcons.check,
      StepTone.failed => AppIcons.close,
      StepTone.pending => Icons.more_horiz,
      StepTone.neutral => AppIcons.dash,
      StepTone.info => AppIcons.hook,
      StepTone.running => null,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: tone == StepTone.pending ? Border.all(color: context.colors.outline, width: 2) : null,
      ),
      alignment: Alignment.center,
      child: tone == StepTone.running
          ? SizedBox.square(
              dimension: size * 0.5,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: fg, backgroundColor: fg.withValues(alpha: 0.25)),
            )
          : Icon(icon ?? defaultIcon, size: size * 0.56, color: fg),
    );
  }
}

/// Vertical connector between timeline steps: 2px outlineVariant.
class StepConnector extends StatelessWidget {
  const StepConnector({super.key, this.minHeight = 12});
  final double minHeight;

  @override
  Widget build(BuildContext context) => Container(
    width: 2,
    constraints: BoxConstraints(minHeight: minHeight),
    color: context.colors.outlineVariant,
  );
}

/// A vertical timeline: icon column with connectors, content column.
class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.items, this.iconColumnWidth = 36, this.gap = 16});

  final List<(Widget icon, Widget content)> items;
  final double iconColumnWidth;
  final double gap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < items.length; i++)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: iconColumnWidth,
                child: Column(
                  children: [
                    items[i].$1,
                    if (i < items.length - 1) const Expanded(child: StepConnector()),
                  ],
                ),
              ),
              SizedBox(width: gap),
              Expanded(child: items[i].$2),
            ],
          ),
        ),
    ],
  );
}
