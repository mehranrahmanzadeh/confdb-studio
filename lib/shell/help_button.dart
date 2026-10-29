import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'product_tour.dart';

/// Documentation and the current page's coach-mark tour.
class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.compact});

  final bool compact;

  Future<void> _openDocs(BuildContext context, String url) async {
    try {
      final result = await Process.run('xdg-open', [url]);
      if (result.exitCode != 0) {
        throw ProcessException('xdg-open', [url], '${result.stderr}', result.exitCode);
      }
    } on ProcessException catch (error) {
      if (context.mounted) {
        showConfirmation(context, Text('Could not open documentation: $error'), kind: MessageKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final route = context.app.route;
    return MenuAnchor(
      alignmentOffset: const Offset(12, 0),
      style: MenuStyle(
        alignment: AlignmentDirectional.topEnd,
        side: WidgetStatePropertyAll(BorderSide(color: c.outlineVariant)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.schemas),
          trailingIcon: const Icon(AppIcons.openDetails, size: 16),
          onPressed: () => _openDocs(context, 'https://snapcraft.io/docs/explanation/how-snaps-work/confdb-configuration-mechanism/'),
          child: const Text('Confdb documentation'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.terminal),
          trailingIcon: const Icon(AppIcons.openDetails, size: 16),
          onPressed: () => _openDocs(context, 'https://snapcraft.io/docs/how-to-guides/snap-development/use-snapctl/'),
          child: const Text('snapctl documentation'),
        ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.retry),
          onPressed: ProductTour.keysForRoute(route) == null ? null : () => ProductTour.replay(context, route),
          child: const Text('Replay page tooltips'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Help',
        child: Semantics(
          button: true,
          label: 'Help',
          excludeSemantics: true,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            borderRadius: BorderRadius.circular(12),
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            child: SizedBox(
              width: compact ? 56 : 80,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.help, color: c.onSurfaceVariant),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text('Help', style: context.text.labelMedium?.copyWith(color: c.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
