import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';

/// Type chip: tertiaryContainer, mono 11 (`string`, `enum`, `array<string>`).
class TypeChip extends StatelessWidget {
  const TypeChip(this.type, {super.key});
  final String type;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: c.tertiaryContainer, borderRadius: BorderRadius.circular(ConfdbRadii.typeChip)),
      child: _Centered(
        Text(
          type,
          style: context.text.labelSmall?.mono.copyWith(
            fontSize: 11,
            height: 16 / 11,
            color: c.onTertiaryContainer,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// Ephemeral marker: secondaryContainer, bolt icon + label.
class EphemeralChip extends StatelessWidget {
  const EphemeralChip({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.fromLTRB(4, 0, 6, 0),
      decoration: BoxDecoration(color: c.secondaryContainer, borderRadius: BorderRadius.circular(ConfdbRadii.typeChip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.bolt, size: 13, color: c.onSecondaryContainer),
          const SizedBox(width: 3),
          Text('Ephemeral', style: context.text.labelMedium?.copyWith(color: c.onSecondaryContainer)),
        ],
      ),
    );
  }
}

/// View chip: `wifi-state · r` on surfaceContainerLow with an outlineVariant border.
class ViewChip extends StatelessWidget {
  const ViewChip(this.label, {super.key, this.background});
  final String label;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: background ?? c.surfaceContainerLow,
        border: Border.all(color: c.outlineVariant),
        borderRadius: BorderRadius.circular(ConfdbRadii.chip),
      ),
      child: _Centered(Text(label, style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant))),
    );
  }
}

/// Custodian (shield, secondaryContainer) or Observer (eye, surfaceContainerHigh).
class RoleChip extends StatelessWidget {
  const RoleChip(this.role, {super.key});
  final PlugRole role;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final custodian = role == PlugRole.custodian;
    final fg = custodian ? c.onSecondaryContainer : c.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.fromLTRB(4, 0, 6, 0),
      decoration: BoxDecoration(
        color: custodian ? c.secondaryContainer : c.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ConfdbRadii.typeChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(custodian ? AppIcons.shield : AppIcons.eye, size: 12, color: fg),
          const SizedBox(width: 3),
          Text(
            role.label,
            style: context.text.labelSmall?.copyWith(fontSize: 11, color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Access with its icon, as in the Data explorer's Access column.
class AccessLabel extends StatelessWidget {
  const AccessLabel(this.access, {super.key});
  final RuleAccess access;

  static IconData iconFor(RuleAccess a) => switch (a) {
    RuleAccess.readWrite => AppIcons.readWrite,
    RuleAccess.write => AppIcons.edit,
    RuleAccess.read => AppIcons.eye,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconFor(access), size: 16, color: c.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(access.label, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ),
      ],
    );
  }
}

/// Vertically centers a chip's label without making the chip expand.
class _Centered extends StatelessWidget {
  const _Centered(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Flexible(child: child)],
  );
}

/// Secret marker (`"visibility": "secret"`): lock icon + label.
class SecretChip extends StatelessWidget {
  const SecretChip({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Secret: only admins can read it',
      child: Container(
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.fromLTRB(4, 0, 6, 0),
        decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(ConfdbRadii.typeChip)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.lock, size: 13, color: c.onSurface),
            const SizedBox(width: 3),
            Text('Secret', style: context.text.labelMedium?.copyWith(color: c.onSurface)),
          ],
        ),
      ),
    );
  }
}
