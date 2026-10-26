import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('map "required" keys', () {
    Future<void> openEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ConfdbStudioApp(
          repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
          initialRoute: const SchemaEditorRoute(networkId),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('adding a required combination shows it in the tree, and it can be removed', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Actions for wifi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Require some keys'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'ssid'));
      await tester.tap(find.widgetWithText(FilterChip, 'psk'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('requires ssid & psk'), findsOneWidget);

      // Editing again and removing the combination clears the requirement.
      await tester.tap(find.byTooltip('Actions for wifi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove combination'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('requires'), findsNothing);
    });
  });
}
