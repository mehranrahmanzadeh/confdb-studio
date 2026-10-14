import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/staging_controller.dart';
import '../widgets/common.dart';
import '../util/format.dart';
import 'app_rail.dart';
import 'pending_tray.dart';
import 'screen_host.dart';

/// Below this width the rail shows icons only and screens stack their panes.
const compactBreakpoint = 1200.0;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactBreakpoint;

/// Rail + content + pending tray.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final staging = context.staging;
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([app, staging]),
        builder: (context, _) {
          final compact = isCompact(context);
          final route = app.route;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FocusTraversalGroup(
                child: AppRail(selected: route.destination, compact: compact, onSelected: app.goTo),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: FocusTraversalGroup(
                        child: KeyedSubtree(key: ValueKey(route.runtimeType), child: buildScreen(route)),
                      ),
                    ),
                    if (!staging.isEmpty)
                      FocusTraversalGroup(
                        child: PendingTray(
                          staging: staging,
                          onReview: () => openReview(context),
                          onDiscard: () => _discard(context, staging),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _discard(BuildContext context, StagingController staging) {
    final saved = staging.all;
    staging.discardAll();
    showConfirmation(
      context,
      Text('Discarded ${plural(saved.length, 'staged change')}'),
      actionLabel: 'Undo',
      onAction: () => saved.forEach(staging.stage),
    );
  }
}
