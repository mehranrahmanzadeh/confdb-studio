import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';
import 'cli_disclosure.dart';
import 'code_text.dart';
import 'status_badge.dart';

/// Bordered container on surfaceContainerLowest, radius 12 (tables, lists).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = EdgeInsets.zero, this.color, this.radius = ConfdbRadii.card});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surfaceContainerLowest,
        border: Border.all(color: c.outlineVariant),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}

/// Unbordered panel on surfaceContainerLow (side panels, the why-check).
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(color: context.colors.surfaceContainerLow, borderRadius: BorderRadius.circular(ConfdbRadii.card)),
    child: child,
  );
}

/// Page title (headlineMedium) with an optional subtitle and trailing widget.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final Widget? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(title, style: context.text.headlineMedium)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            child: subtitle!,
          ),
        ],
      ],
    );
    if (trailing == null) return head;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.end,
      alignment: WrapAlignment.spaceBetween,
      children: [
        ConstrainedBox(constraints: const BoxConstraints(minWidth: 360), child: head),
        trailing!,
      ],
    );
  }
}

/// Section heading (titleMedium) with an optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 40),
    child: Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text(title, style: context.text.titleMedium)),
        ),
        ?action,
      ],
    ),
  );
}

/// Centered empty state: icon tile, title, body, actions, CLI.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.actions = const [], this.command});
  final IconData icon;
  final String title;
  final Widget body;
  final List<Widget> actions;
  final String? command;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 72),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(ConfdbRadii.card)),
                child: Icon(icon, color: c.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Text(title, style: context.text.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                child: body,
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: actions),
              ],
              if (command != null) ...[const SizedBox(height: 12), CliDisclosure(command!)],
            ],
          ),
        ),
      ),
    );
  }
}

enum MessageKind { error, warning, info, success }

/// Inline message for persistent issues (role="alert"/"status" in the designs).
class InlineMessage extends StatelessWidget {
  const InlineMessage({
    super.key,
    required this.kind,
    required this.title,
    this.body,
    this.actions = const [],
    this.padding = const EdgeInsets.all(16),
    this.large = false,
  });

  final MessageKind kind;
  final String title;
  final Widget? body;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  /// Page-level errors use a bigger title (titleMedium).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final (bg, fg, icon) = switch (kind) {
      MessageKind.error => (c.errorContainer, c.onErrorContainer, AppIcons.error),
      MessageKind.warning => (s.warningContainer, s.onWarningContainer, AppIcons.warning),
      MessageKind.info => (s.informationContainer, s.onInformationContainer, AppIcons.info),
      MessageKind.success => (s.successContainer, s.onSuccessContainer, AppIcons.ok),
    };
    return Semantics(
      liveRegion: kind == MessageKind.error,
      container: true,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(ConfdbRadii.card)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: large ? 24 : 20),
            SizedBox(width: large ? 16 : 12),
            Expanded(
              child: DefaultTextStyle.merge(
                style: context.text.bodyMedium?.copyWith(color: fg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: (large ? context.text.titleMedium : context.text.bodyMedium)?.copyWith(color: fg, fontWeight: FontWeight.w600),
                    ),
                    if (body != null) ...[const SizedBox(height: 6), body!],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outlined button drawn in the message's on-container color (Retry, Retry load).
class OnContainerButton extends StatelessWidget {
  const OnContainerButton({super.key, required this.label, required this.onPressed, this.icon, this.outlined = true});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final fg = DefaultTextStyle.of(context).style.color ?? context.colors.onErrorContainer;
    final style = (outlined ? OutlinedButton.styleFrom : TextButton.styleFrom)(
      foregroundColor: fg,
      side: outlined ? BorderSide(color: fg) : null,
      padding: EdgeInsets.fromLTRB(icon == null ? 12 : 16, 0, outlined ? 20 : 12, 0),
    );
    final child = icon == null
        ? Text(label)
        : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 8), Text(label)]);
    return outlined
        ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : TextButton(onPressed: onPressed, style: style, child: child);
  }
}

/// Filled button with an optional leading icon and a progress spinner while busy.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    style: FilledButton.styleFrom(padding: EdgeInsets.fromLTRB(icon == null && !busy ? 24 : 16, 0, 24, 0)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else if (icon != null)
          Icon(icon, size: 18),
        if (busy || icon != null) const SizedBox(width: 8),
        Text(label),
      ],
    ),
  );
}

/// Outlined (secondary) button with an optional leading icon.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: busy ? null : onPressed,
    style: OutlinedButton.styleFrom(padding: EdgeInsets.fromLTRB(icon == null && !busy ? 20 : 16, 0, 20, 0)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else if (icon != null)
          Icon(icon, size: 18),
        if (busy || icon != null) const SizedBox(width: 8),
        Text(label),
      ],
    ),
  );
}

/// Text (secondary) button with an optional leading icon.
class TertiaryButton extends StatelessWidget {
  const TertiaryButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(padding: EdgeInsets.fromLTRB(icon == null ? 12 : 8, 0, icon == null ? 12 : 16, 0)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Text(label),
      ],
    ),
  );
}

/// Two-column `<dl>`: label in onSurfaceVariant, value in onSurface.
class DetailList extends StatelessWidget {
  const DetailList({super.key, required this.rows, this.labelWidth = 112});
  final List<(String, Widget)> rows;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(rows[i].$1, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(style: context.text.bodyMedium, child: rows[i].$2),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Table header row: labelMedium w600, onSurfaceVariant, letter spacing 0.4.
TextStyle? tableHeaderStyle(BuildContext context) =>
    context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.4, color: context.colors.onSurfaceVariant);

/// Group header row inside tables ("Today", "acme").
class GroupHeaderRow extends StatelessWidget {
  const GroupHeaderRow({super.key, required this.child, this.minHeight = 36});
  final Widget child;
  final double minHeight;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minHeight: minHeight),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: context.colors.surfaceContainerLow,
      border: Border(bottom: BorderSide(color: context.colors.outlineVariant)),
    ),
    child: child,
  );
}

/// Loading state for tables: indeterminate bar, spinner + message, skeleton rows.
class TableSkeleton extends StatelessWidget {
  const TableSkeleton({super.key, required this.message, required this.columns, this.rows = const [0.62, 0.48, 0.7, 0.55, 0.4, 0.66]});
  final String message;

  /// Flex weights of the skeleton columns; the first is darker.
  final List<int> columns;
  final List<double> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget bar(Color color, double widthFactor, {double height = 12}) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      ),
    );
    return Semantics(
      label: message,
      liveRegion: true,
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(minHeight: 4),
            Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.outlineVariant)),
              ),
              child: Row(
                children: [
                  SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.onSurfaceVariant)),
                  const SizedBox(width: 10),
                  Text(message, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
            ),
            for (final w in rows)
              Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outlineVariant)),
                ),
                child: Row(
                  children: [
                    for (var i = 0; i < columns.length; i++) ...[
                      if (i > 0) const SizedBox(width: 24),
                      Expanded(
                        flex: columns[i],
                        child: i == 0
                            ? bar(c.surfaceContainerHigh, 0.8)
                            : i == columns.length - 1
                            ? bar(c.surfaceContainerHigh, 1, height: 22)
                            : bar(c.surfaceContainer, i == 1 ? w : 1),
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

/// A page-level load error with Retry and a diagnostic command.
class LoadErrorMessage extends StatelessWidget {
  const LoadErrorMessage({super.key, required this.title, required this.error, required this.onRetry, this.command});
  final String title;
  final Object error;
  final VoidCallback onRetry;
  final String? command;

  @override
  Widget build(BuildContext context) => InlineMessage(
    kind: MessageKind.error,
    large: true,
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
    title: 'Error · $title',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CodeText('$error'),
        const SizedBox(height: 12),
        OnContainerButton(label: 'Retry', icon: AppIcons.retry, onPressed: onRetry),
        if (command != null) ...[const SizedBox(height: 8), CliDisclosure(command!, initiallyOpen: true)],
      ],
    ),
  );
}

/// A small badge-like count pill used in trees ("5" rules).
class CountPill extends StatelessWidget {
  const CountPill(this.count, {super.key, this.background, this.foreground, this.semanticLabel});
  final int count;
  final Color? background;
  final Color? foreground;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    excludeSemantics: semanticLabel != null,
    child: Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: background ?? context.colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(11)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$count',
            style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: foreground),
          ),
        ],
      ),
    ),
  );
}

/// Shows a confirmation SnackBar (with an optional "View" or "Undo" action).
void showConfirmation(BuildContext context, Widget message, {String? actionLabel, VoidCallback? onAction}) =>
    showToast(ScaffoldMessenger.of(context), message, actionLabel: actionLabel, onAction: onAction);

/// Every confirmation goes through here. Flutter keeps a SnackBar with an
/// action on screen until dismissed (`persist` defaults to true then), so
/// confirmations opt out: they hide after [duration] and have a close button.
void showToast(
  ScaffoldMessengerState messenger,
  Widget message, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 6),
}) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: message,
      width: 480,
      duration: duration,
      persist: false,
      showCloseIcon: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ),
  );
}

/// Badge used for change status everywhere.
StatusBadge changeStatusBadge(String label, {required bool done, required bool error, required bool running}) {
  if (running) return StatusBadge.running(label);
  if (error) return StatusBadge.error(label);
  if (done) return StatusBadge.success(label);
  return StatusBadge.neutral(label);
}

/// CSS `repeat(auto-fit, minmax(min(minItemWidth, 100%), 1fr))`: as many equal
/// columns as fit, rows stretched to the tallest item.
class AutoGrid extends StatelessWidget {
  const AutoGrid({super.key, required this.minItemWidth, required this.children, this.spacing = 16, this.runSpacing, this.stretch = true});
  final double minItemWidth;
  final List<Widget> children;
  final double spacing;
  final double? runSpacing;

  /// Stretch items in a row to equal height (tiles); false aligns them at the top.
  final bool stretch;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final w = constraints.maxWidth;
      final cols = ((w + spacing) / (minItemWidth + spacing)).floor().clamp(1, children.isEmpty ? 1 : children.length);
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += cols) {
        final slice = children.sublist(i, (i + cols).clamp(0, children.length));
        final row = Row(
          crossAxisAlignment: stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) SizedBox(width: spacing),
              Expanded(child: j < slice.length ? slice[j] : const SizedBox.shrink()),
            ],
          ],
        );
        if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing ?? spacing));
        rows.add(stretch ? IntrinsicHeight(child: row) : row);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    },
  );
}

/// Scrollable page body using the full width, padding 24/32/40 as in the designs.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.gap = 24, this.padding = const EdgeInsets.fromLTRB(32, 24, 32, 40)});
  final List<Widget> children;
  final double gap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
      ],
    ),
  );
}

/// A tappable row inside a [SectionCard]: divider above all but the first.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.child,
    this.onTap,
    this.first = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.color,
    this.semanticLabel,
  });
  final Widget child;
  final VoidCallback? onTap;
  final bool first;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Container(
      decoration: BoxDecoration(
        color: color,
        border: first ? null : Border(top: BorderSide(color: context.colors.outlineVariant)),
      ),
      child: onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                mouseCursor: WidgetStateMouseCursor.clickable,
                onTap: onTap,
                child: Semantics(button: true, label: semanticLabel, child: content),
              ),
            ),
    );
  }
}

/// A rounded placeholder bar for loading skeletons.
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({super.key, this.width, this.height = 12, this.strong = false});
  final double? width;
  final double height;

  /// surfaceContainerHigh instead of surfaceContainer, for titles.
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: strong ? context.colors.surfaceContainerHigh : context.colors.surfaceContainer,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}

/// Spinner + message, for screens loading their content.
class LoadingRow extends StatelessWidget {
  const LoadingRow(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      children: [
        SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: context.colors.onSurfaceVariant)),
        const SizedBox(width: 10),
        Text(message, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
      ],
    ),
  );
}

/// Asks before a destructive action; the confirm button uses the error colour.
Future<bool> confirmDestructive(BuildContext context, {required Widget title, required Widget body, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: title,
      content: SizedBox(width: 440, child: body),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: context.colors.error, foregroundColor: context.colors.onError),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks before an action that isn't destructive but can't be taken back,
/// like registering an assertion in the Snap Store.
Future<bool> confirmAction(BuildContext context, {required Widget title, required Widget body, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: title,
      content: SizedBox(width: 440, child: body),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}
