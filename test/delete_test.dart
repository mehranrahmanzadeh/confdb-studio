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

  test('a removed view is one diff line', () {
    final draft = networkRev4.copyWith(views: networkRev4.views.where((v) => v.name != 'proxy-state').toList());
    final diff = diffSchemas(networkRev4, draft);
    expect(diff, hasLength(1));
    expect(diff.single.added, isFalse);
    expect(diff.single.where, 'proxy-state');
    expect(diff.single.what, startsWith('view and its'));
  });

  testWidgets('deleting a view names the plugs that lose it and drops it from the draft', (tester) async {
    final r = repo();
    await open(tester, r, const SchemaEditorRoute(networkId, view: 'wifi-state'));
    await tester.tap(find.byTooltip('Delete view wifi-state'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wifi-indicator:'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete view'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
    final drafts = (await tester.runAsync(r.listDrafts))!;
    final draft = drafts.singleWhere((d) => d.id == networkId);
    expect(draft.view('wifi-state'), isNull);
    expect(draft.views, isNotEmpty);
  });

  testWidgets('a draft can be discarded from the schemas list', (tester) async {
    final r = repo();
    await open(tester, r, const SchemasRoute());
    await tester.tap(find.byTooltip('Actions for acme/network'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard draft'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Revision 4 stays acknowledged'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Discard draft'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(r.listDrafts))!.where((d) => d.id == networkId), isEmpty);
    expect(find.byTooltip('Actions for acme/network'), findsNothing);
  });
}
