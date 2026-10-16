import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a read refused for want of a custodian is a warning, not an error', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero, noCustodian: true)),
        initialRoute: const DataRoute(view: ViewRef(acmeAccountId, 'telemetry', 'telemetry-admin')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Warning · No custodian snap connected'), findsOneWidget);
    expect(find.textContaining('Error ·'), findsNothing);
    await tester.tap(find.text('How to connect a custodian'));
    await tester.pumpAndSettle();
    expect(find.textContaining('telemetry-agent:telemetry-admin'), findsOneWidget);
  });
}
