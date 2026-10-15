import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a signed schema with unsigned draft changes gets a badge in the untitled column', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemasRoute()));
    await tester.pumpAndSettle();
    // The sample data has one draft: of network, which is signed.
    expect(find.text('Draft changes'), findsOneWidget);
    expect(find.byTooltip(RegExp(r'\d+ changes? not signed yet')), findsOneWidget);

    await tester.runAsync(() => repo.discardDraft(networkId));
    await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemasRoute()));
    await tester.pumpAndSettle();
    expect(find.text('Draft changes'), findsNothing);
  });
}
