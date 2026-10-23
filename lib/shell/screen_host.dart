import 'package:flutter/material.dart';

import '../screens/access/access_screen.dart';
import '../screens/data/data_explorer_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/overview/overview_screen.dart';
import '../screens/review/review_sheet.dart';
import '../screens/schema_editor/schema_editor_screen.dart';
import '../screens/sign/sign_dialog.dart';
import '../data/models.dart';
import '../state/app_controller.dart';

/// Maps a route to its screen.
Widget buildScreen(AppRoute route) => switch (route) {
  OverviewRoute() => const OverviewScreen(),
  DataRoute() => DataExplorerScreen(route: route),
  AccessRoute() => AccessScreen(route: route),
  // One screen for both steps, so the draft and header stay put between them.
  AuthoringRoute() => SchemaEditorScreen(route: route),
  OnboardingRoute() => OnboardingScreen(route: route),
};

/// Opens 7.5 Sign & acknowledge for a draft with the key chosen on the
/// editor's signing-key step. On success, [view] decides which view the
/// playground step (reached after acknowledging) opens to.
void openSignDialog(BuildContext context, ConfdbSchema draft, ConfdbSchema? base, SigningKey key, {bool? keyRegistered, String? view}) =>
    showSignDialog(context, draft, base, key, keyRegistered: keyRegistered, view: view);

/// Opens the Review & apply side sheet for everything staged.
void openReview(BuildContext context) => showReviewSheet(context);
