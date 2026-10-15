import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/screens/playground/playground_screen.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(WidgetTester tester, AppRoute route) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
        initialRoute: route,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

  testWidgets('Next leads from the editor to the playground, under the same header, and on to signing', (tester) async {
    await open(tester, const SchemaEditorRoute(networkId));
    await tester.tap(find.textContaining('Add wifi.signal'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(button('Sign & acknowledge'), findsNothing, reason: 'the editor offers Next');
    expect(find.bySemanticsLabel(RegExp('step 3 of 5, Lint')), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaygroundPanel), findsOneWidget);
    expect(find.bySemanticsLabel('Schema summary'), findsOneWidget, reason: 'the header stays');
    expect(find.bySemanticsLabel(RegExp('step 4 of 5, Playground')), findsOneWidget);
    expect(find.text('Next'), findsNothing);

    // A denied simulation doesn't stop signing.
    await tester.enterText(find.widgetWithText(TextField, 'Request path'), 'no.such.path');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Denied at step'), findsOneWidget);
    await tester.tap(button('Sign & acknowledge'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('a snap with no plug for the view gets a guide to add one', (tester) async {
    await open(tester, const PlaygroundRoute(networkId, view: 'wifi-admin', snap: 'browser-proxy'));
    expect(find.text('No plug for this view'), findsWidgets);
    await tester.ensureVisible(find.text('More info'));
    await tester.tap(find.text('More info'));
    await tester.pumpAndSettle();
    expect(find.textContaining('view: network/wifi-admin'), findsOneWidget);
    expect(find.text('sudo snap connect browser-proxy:wifi-admin'), findsOneWidget);
    await tester.tap(find.text('Custodian'));
    await tester.pumpAndSettle();
    expect(find.textContaining('role: custodian'), findsOneWidget);
  });

  testWidgets('Back returns to the editor with the draft intact', (tester) async {
    await open(tester, const SchemaEditorRoute(networkId));
    await tester.tap(find.textContaining('Add wifi.signal'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaygroundPanel), findsNothing);
    expect(find.textContaining('Add wifi.signal'), findsNothing, reason: 'the quick fix is still applied');
    expect(find.text('Next'), findsOneWidget);
  });
}
