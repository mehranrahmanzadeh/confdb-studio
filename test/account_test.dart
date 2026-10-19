import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rail account button', () {
    Future<void> boot(WidgetTester tester, FakeScenario scenario) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ConfdbStudioApp(repository: FakeConfdbRepository(scenario: scenario)));
      await tester.pumpAndSettle();
    }

    testWidgets('warns and offers to sign in when signed out of the Snap Store', (tester) async {
      await boot(tester, const FakeScenario(latency: Duration.zero, storeSignedOut: true));
      final tooltip = find.byTooltip('Not signed in to the Snap Store: you can’t sign schemas');
      expect(tooltip, findsOneWidget);
      await tester.tap(tooltip);
      await tester.pumpAndSettle();
      expect(find.text('Sign in to see the schemas registered to your account, push new revisions, and register signing keys.'), findsOneWidget);
    });

    testWidgets('shows the username when signed in', (tester) async {
      await boot(tester, const FakeScenario(latency: Duration.zero));
      expect(find.text('Sign in'), findsNothing);
      expect(find.byTooltip('Signed in to the Snap Store as acme'), findsOneWidget);
    });
  });

  testWidgets('sign dialog guides key creation when there are no keys', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero, noKeys: true)),
        initialRoute: const SchemaEditorRoute(networkId),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Add wifi.signal'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('No signing keys found'), findsOneWidget);
    expect(find.text('Create key'), findsOneWidget);
    await tester.tap(find.text('Refresh keys'));
    await tester.pumpAndSettle();
    expect(find.text('No signing keys found'), findsOneWidget);
  });
}
