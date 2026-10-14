import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';

/// Small snapd version and confdb status at the bottom of the rail.
/// Icon + text, never color alone; the full text is in the tooltip.
class SnapdStatus extends StatelessWidget {
  const SnapdStatus({super.key, required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final c = context.colors;
        final s = context.status;
        final st = app.status;
        final (Widget icon, Color color, String state, String tooltip) = switch ((st, app.statusError)) {
          (_, true) => (
            Icon(AppIcons.error, size: 14, color: c.error),
            c.error,
            'unreachable',
            'snapd isn’t responding on /run/snapd.socket',
          ),
          (null, _) => (
            SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.onSurfaceVariant)),
            c.onSurfaceVariant,
            'checking…',
            'Checking snapd',
          ),
          (final st?, _) when st.confdbEnabled => (
            Icon(AppIcons.ok, size: 14, color: s.success),
            s.success,
            'confdb on',
            'snapd ${st.snapdVersion} · confdb enabled',
          ),
          (final st?, _) => (
            Icon(AppIcons.warning, size: 14, color: s.warning),
            s.warning,
            'confdb off',
            'snapd ${st.snapdVersion} · confdb not enabled',
          ),
        };
        final small = context.text.labelSmall?.copyWith(fontSize: 10, height: 14 / 10, letterSpacing: 0.2);
        return Tooltip(
          message: tooltip,
          child: Semantics(
            label: tooltip,
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(height: 2),
                  if (!compact)
                    Text(
                      state,
                      style: small?.copyWith(color: color, fontWeight: FontWeight.w600),
                    ),
                  Text(st == null ? 'snapd' : 'snapd ${st.snapdVersion}', style: small?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
