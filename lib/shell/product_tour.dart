import 'dart:io';

import 'package:flutter/material.dart';
import 'package:showcaseview/showcaseview.dart';

import '../data/app_data.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';

/// A [Showcase] styled to match the app's dark theme instead of the
/// package's default white tooltip. Use this (not [Showcase] directly) for
/// every tour step.
Widget tourShowcase(
  BuildContext context, {
  required GlobalKey key,
  required String title,
  required String description,
  required Widget child,
}) {
  final c = context.colors;
  return Showcase(
    key: key,
    title: title,
    titleTextStyle: context.text.titleMedium?.copyWith(color: c.primary, fontWeight: FontWeight.w600),
    description: description,
    descTextStyle: context.text.bodyMedium?.copyWith(color: c.onSurface),
    tooltipBackgroundColor: c.surfaceContainerHigh,
    tooltipBorderRadius: BorderRadius.circular(ConfdbRadii.card),
    targetBorderRadius: BorderRadius.circular(ConfdbRadii.button),
    targetPadding: const EdgeInsets.all(4),
    child: child,
  );
}

/// Coach-mark keys for the first-run tours (see [ProductTour]). Rail
/// destinations swap their icon widget between selected/unselected variants,
/// but never both at once, so the same key is reused across them.
class TourKeys {
  TourKeys._();

  // Overview: the rail, the account button and the schemas page header.
  static final railSchema = GlobalKey(debugLabel: 'tour-rail-schema');
  static final railData = GlobalKey(debugLabel: 'tour-rail-data');
  static final railAccess = GlobalKey(debugLabel: 'tour-rail-access');
  static final account = GlobalKey(debugLabel: 'tour-account');
  static final newSchema = GlobalKey(debugLabel: 'tour-new-schema');
  static final overview = [railSchema, railData, railAccess, account, newSchema];

  // New schema: picking a template, naming it, and opening the editor.
  static final chooseTemplate = GlobalKey(debugLabel: 'tour-choose-template');
  static final chooseName = GlobalKey(debugLabel: 'tour-choose-name');
  static final chooseOpen = GlobalKey(debugLabel: 'tour-choose-open');
  static final choose = [chooseTemplate, chooseName, chooseOpen];

  // Schema editor: the views, rules and storage panes, then Next.
  static final editorViews = GlobalKey(debugLabel: 'tour-editor-views');
  static final editorRules = GlobalKey(debugLabel: 'tour-editor-rules');
  static final editorStorage = GlobalKey(debugLabel: 'tour-editor-storage');
  static final editorNext = GlobalKey(debugLabel: 'tour-editor-next');
  static final editor = [editorViews, editorRules, editorStorage, editorNext];

  /// First step of each tour: hides the "Previous" action there.
  static final firstOfEach = [railSchema, chooseTemplate, editorViews];

  /// Last step of each tour: hides the "Next" action there, in favor of "Done".
  static final lastOfEach = [newSchema, chooseOpen, editorNext];

  /// Every step that's not a tour's last: hides the "Done" action there.
  static final notLastOfEach = [...overview, ...choose, ...editor].where((k) => !lastOfEach.contains(k)).toList();
}

/// Drives the first-run coach-mark tours with `showcaseview`: one for the
/// overview/rail, one for picking a new schema, one for the editor. Each
/// remembers (in a marker file under [appDataDir]) that it has run, so it
/// only shows once per install.
class ProductTour {
  ProductTour._();

  static bool _registered = false;
  static String? _activeStage;

  /// Only pages with their own tour can replay it; authoring's later steps
  /// must not replay the schema editor's hidden targets.
  static List<GlobalKey>? keysForRoute(AppRoute route) => switch (route) {
    OverviewRoute() => TourKeys.overview,
    OnboardingRoute(choose: true) => TourKeys.choose,
    SchemaEditorRoute() => TourKeys.editor,
    _ => null,
  };

  /// Replays just this page without clearing any first-run markers. Wait for
  /// the Help menu to close and omit targets hidden by the compact layout.
  static void replay(BuildContext context, AppRoute route) {
    final pageKeys = keysForRoute(route);
    if (pageKeys == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ensureRegistered();
      final showcase = ShowcaseView.get();
      final keys = pageKeys.where(showcase.isTargetRendered).toList();
      if (keys.isEmpty) return;
      showcase.dismiss();
      showcase.startShowCase(keys);
    });
  }

  /// Registers the showcase view once per process. Safe to call repeatedly.
  static void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    ShowcaseView.register(
      disableMovingAnimation: true,
      disableScaleAnimation: true,
      blurValue: 0.6,
      globalTooltipActionConfig: const TooltipActionConfig(
        position: TooltipActionPosition.inside,
        alignment: MainAxisAlignment.spaceBetween,
      ),
      globalTooltipActions: [
        TooltipActionButton(type: TooltipDefaultActionType.previous, hideActionWidgetForShowcase: TourKeys.firstOfEach),
        TooltipActionButton(type: TooltipDefaultActionType.next, hideActionWidgetForShowcase: TourKeys.lastOfEach),
        TooltipActionButton(
          type: TooltipDefaultActionType.next,
          name: 'Done',
          onTap: () => ShowcaseView.get().dismiss(),
          hideActionWidgetForShowcase: TourKeys.notLastOfEach,
        ),
      ],
      onFinish: _markActiveStageSeen,
      onDismiss: (_) => _markActiveStageSeen(),
    );
  }

  static void _markActiveStageSeen() {
    final stage = _activeStage;
    _activeStage = null;
    if (stage != null) markSeen(stage);
  }

  static File _marker(String stage) => File(appDataPath('tour_${stage}_seen'));

  /// Whether [stage]'s tour has already run (or been skipped) on this device.
  static Future<bool> hasBeenSeen(String stage) async {
    try {
      return await _marker(stage).exists();
    } catch (_) {
      return true; // Don't keep nagging if we can't tell.
    }
  }

  static Future<void> markSeen(String stage) async {
    try {
      final f = _marker(stage);
      await f.parent.create(recursive: true);
      await f.writeAsString(DateTime.now().toIso8601String());
    } catch (_) {
      // Best effort; worst case that tour runs again next time.
    }
  }

  /// Starts [stage]'s tour over [keys] if it hasn't been seen yet. Safe to
  /// call every time the relevant screen is shown; it's a no-op once that
  /// tour has run.
  static Future<void> startIfNeeded(BuildContext context, String stage, List<GlobalKey> keys) async {
    // Widget tests don't exercise onboarding and shouldn't leave a pending
    // overlay/timer behind when the test tree is torn down.
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    if (await hasBeenSeen(stage)) return;
    if (!context.mounted) return;
    ensureRegistered();
    _activeStage = stage;
    ShowcaseView.get().startShowCase(keys, delay: const Duration(milliseconds: 400));
  }
}
