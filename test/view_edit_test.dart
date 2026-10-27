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

  testWidgets('a view can be renamed from the schema editor', (tester) async {
    final r = repo();
    await open(tester, r, const SchemaEditorRoute(networkId, view: 'wifi-state'));
    final field = find.byWidgetPredicate((w) => w is TextField && w.decoration?.errorText == null && (w.controller?.text == 'wifi-state'));
    await tester.enterText(field, 'wifi-status');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
    final drafts = (await tester.runAsync(r.listDrafts))!;
    final draft = drafts.singleWhere((d) => d.id == networkId);
    expect(draft.view('wifi-state'), isNull);
    expect(draft.view('wifi-status'), isNotNull);
  });

  testWidgets('renaming a view to an existing name is rejected', (tester) async {
    final r = repo();
    await open(tester, r, const SchemaEditorRoute(networkId, view: 'wifi-state'));
    final field = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'wifi-state');
    await tester.enterText(field, 'proxy-state'); // another existing view
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('A view with this name exists'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500)); // would-be draft autosave
    final drafts = (await tester.runAsync(r.listDrafts))!;
    final draft = drafts.singleWhere((d) => d.id == networkId);
    expect(draft.view('wifi-state'), isNotNull, reason: 'rejected rename should not change the view');
  });

  testWidgets("a view's summary can be edited from the schema editor", (tester) async {
    final r = repo();
    await open(tester, r, const SchemaEditorRoute(networkId, view: 'wifi-state'));
    final field = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Add a view summary');
    await tester.enterText(field, 'Wi-Fi connection state');
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
    final drafts = (await tester.runAsync(r.listDrafts))!;
    final draft = drafts.singleWhere((d) => d.id == networkId);
    expect(draft.view('wifi-state')!.summary, 'Wi-Fi connection state');
  });

  testWidgets('the views panel can be collapsed and expanded', (tester) async {
    await open(tester, repo(), const SchemaEditorRoute(networkId, view: 'wifi-state'));
    expect(find.byTooltip('Collapse views panel'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse views panel'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse views panel'), findsNothing);
    expect(find.byTooltip('Expand views panel'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand views panel'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse views panel'), findsOneWidget);
    expect(find.byTooltip('Expand views panel'), findsNothing);
  });
}
