import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots into the shell with the rail and snapd status', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Schemas'), findsWidgets, reason: 'the overview lists them');
    expect(find.text('Activity'), findsNothing, reason: 'no Activity tab');
    expect(find.text('snapd 2.77'), findsOneWidget);
    expect(find.text('confdb on'), findsOneWidget);
  });
}
