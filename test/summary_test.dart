import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/domain/analysis.dart';
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

  test('a changed summary shows in the diff', () {
    final diff = diffSchemas(networkRev4, networkRev4.copyWith(summary: 'Network settings'));
    expect(diff.map((d) => (d.added, d.where, d.what)), [(false, 'summary', networkRev4.summary), (true, 'summary', 'Network settings')]);
  });

  testWidgets('the summary can be edited in the schema editor', (tester) async {
    final r = repo();
    await open(tester, r, const SchemaEditorRoute(networkId));
    final field = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Add a summary');
    expect(tester.widget<TextField>(field).controller!.text, isNotEmpty);
    await tester.enterText(field, '  Network settings ');
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
    final drafts = (await tester.runAsync(r.listDrafts))!;
    expect(drafts.singleWhere((d) => d.id == networkId).summary, 'Network settings');
  });

  testWidgets('a new schema takes the summary entered when creating it', (tester) async {
    final r = repo();
    await open(tester, r, const OnboardingRoute(choose: true));
    final summary = find.widgetWithText(TextField, 'Summary');
    expect(tester.widget<TextField>(summary).controller!.text, 'Wi-Fi settings', reason: 'prefilled from the template');
    await tester.enterText(find.widgetWithText(TextField, 'Schema name'), 'office-net');
    await tester.enterText(summary, 'Office Wi-Fi');
    await tester.tap(find.text('Open in schema editor'));
    await tester.pumpAndSettle();
    final drafts = (await tester.runAsync(r.listDrafts))!;
    expect(drafts.singleWhere((d) => d.id.name == 'office-net').summary, 'Office Wi-Fi');
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'Office Wi-Fi'), findsOneWidget);
  });
}
