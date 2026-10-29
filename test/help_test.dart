import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/shell/product_tour.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showcaseview/showcaseview.dart';

void main() {
  Future<void> open(WidgetTester tester, AppRoute route, {double width = 1440}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
        initialRoute: route,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Help'));
    await tester.pumpAndSettle();
  }

  testWidgets('Help sits below the profile and offers documentation and page tooltips', (tester) async {
    await open(tester, const OverviewRoute());
    expect(
      tester.getCenter(find.byTooltip('Help')).dy,
      greaterThan(tester.getCenter(find.byTooltip('Signed in to the Snap Store as acme')).dy),
    );
    expect(find.text('Confdb documentation'), findsOneWidget);
    expect(find.text('snapctl documentation'), findsOneWidget);
    await tester.tap(find.text('Replay page tooltips'));
    await tester.pumpAndSettle();
    expect(find.text('Every schema you own or can see lives here, local and Snap Store alike.'), findsOneWidget);
    for (var i = 0; i < TourKeys.overview.length - 1; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Every schema you own or can see lives here, local and Snap Store alike.'), findsNothing);
  });

  for (final width in [1440.0, 1000.0]) {
    testWidgets('replay stays on the editor at width $width', (tester) async {
      await open(tester, const SchemaEditorRoute(networkId), width: width);
      await tester.tap(find.text('Replay page tooltips'));
      await tester.pumpAndSettle();
      expect(
        find.text('Pick a view, then define the rules mapping requests to storage paths.'),
        width < 1200 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Views are the endpoints snaps read and write confdb through; pick one to edit its rules.'),
        width < 1200 ? findsNothing : findsOneWidget,
      );
      final steps = TourKeys.editor.where(ShowcaseView.get().isTargetRendered).length;
      for (var i = 0; i < steps - 1; i++) {
        expect(find.text('Every schema you own or can see lives here, local and Snap Store alike.'), findsNothing);
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Review the exact assertion and its changes before choosing a signing key.'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Review the exact assertion and its changes before choosing a signing key.'), findsNothing);
      expect(find.text('Preview assertion'), findsOneWidget);
    });
  }

  testWidgets('pages without tours keep documentation available but disable replay', (tester) async {
    await open(tester, const DataRoute());
    expect(find.text('Confdb documentation'), findsOneWidget);
    final replay = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Replay page tooltips'));
    expect(replay.onPressed, isNull);
  });

  test('tour selection uses the page, not its shared rail destination', () {
    expect(ProductTour.keysForRoute(const OverviewRoute()), TourKeys.overview);
    expect(ProductTour.keysForRoute(const OnboardingRoute(choose: true)), TourKeys.choose);
    expect(ProductTour.keysForRoute(const SchemaEditorRoute(networkId)), TourKeys.editor);
    for (final route in <AppRoute>[
      const OnboardingRoute(),
      const DataRoute(),
      const AccessRoute(),
      const PreviewRoute(networkId, view: 'wifi-admin'),
      const SigningKeyRoute(networkId, view: 'wifi-admin'),
      const PlaygroundRoute(networkId, view: 'wifi-admin'),
    ]) {
      expect(ProductTour.keysForRoute(route), isNull);
    }
  });
}
