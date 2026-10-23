import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/screens/data/view_values.dart';
import 'package:confdb_studio/screens/schema_editor/storage_pane.dart';
import 'package:confdb_studio/screens/schema_editor/views_pane.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(WidgetTester tester, FakeConfdbRepository repository, AppRoute route) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ConfdbStudioApp(repository: repository, initialRoute: route));
    await tester.pumpAndSettle();
  }

  testWidgets('the storage tree collapses and re-expands a map\'s children', (tester) async {
    await open(tester, FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)), const SchemaEditorRoute(networkId));
    final ssidInTree = find.descendant(of: find.byType(StoragePane), matching: find.text('ssid'));
    expect(ssidInTree, findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Collapse wifi$')));
    await tester.pumpAndSettle();
    expect(ssidInTree, findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Expand wifi$')));
    await tester.pumpAndSettle();
    expect(ssidInTree, findsOneWidget);
  });

  testWidgets('the views pane collapses and re-expands a selected view\'s rules', (tester) async {
    await open(
      tester,
      FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
      const SchemaEditorRoute(networkId, view: 'wifi-admin'),
    );
    final ssidInViews = find.descendant(of: find.byType(ViewsPane), matching: find.text('ssid'));
    expect(ssidInViews, findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Collapse wifi-admin$')));
    await tester.pumpAndSettle();
    expect(ssidInViews, findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Expand wifi-admin$')));
    await tester.pumpAndSettle();
    expect(ssidInViews, findsOneWidget);
  });

  testWidgets('the schemas table collapses and re-expands an account\'s schemas', (tester) async {
    await open(tester, FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)), const OverviewRoute());
    expect(find.text('network'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^Collapse $acmeAccountId\$')));
    await tester.pumpAndSettle();
    expect(find.text('network'), findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp('^Expand $acmeAccountId\$')));
    await tester.pumpAndSettle();
    expect(find.text('network'), findsOneWidget);
  });

  testWidgets('the data explorer values table collapses and re-expands a view\'s keys', (tester) async {
    await open(
      tester,
      FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
      DataRoute(view: networkId.view('wifi-admin')),
    );
    final ssidInTable = find.descendant(of: find.byType(ViewValues), matching: find.text('ssid'));
    expect(ssidInTable, findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Collapse wifi-admin$')));
    await tester.pumpAndSettle();
    expect(ssidInTable, findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Expand wifi-admin$')));
    await tester.pumpAndSettle();
    expect(ssidInTable, findsOneWidget);
  });
}
