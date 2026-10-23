import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FakeConfdbRepository repo() => FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));

  Future<void> open(WidgetTester tester, FakeConfdbRepository repository, AppRoute route) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ConfdbStudioApp(repository: repository, initialRoute: route));
    await tester.pumpAndSettle();
  }

  testWidgets('schema creation offers naming conventions', (tester) async {
    await open(tester, repo(), const OnboardingRoute(choose: true));
    await tester.tap(find.byTooltip('Naming conventions'));
    await tester.pumpAndSettle();
    expect(find.text('Naming conventions'), findsOneWidget, reason: 'the dialog title');
    expect(find.textContaining('X-admin'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Naming conventions'), findsNothing);
  });

  testWidgets('the schema editor offers naming conventions', (tester) async {
    await open(tester, repo(), const SchemaEditorRoute(networkId));
    await tester.tap(find.byTooltip('Naming conventions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('X-admin'), findsOneWidget);
  });
}
