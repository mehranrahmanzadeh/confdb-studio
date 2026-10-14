import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/screens/access/custodian_guide.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the plugs block declares one custodian plug per view', () {
    final yaml = custodianPlugsYaml(networkRev4);
    expect(
      yaml,
      startsWith('plugs:\n  wifi-admin:\n    interface: confdb\n    account: acme\n    view: network/wifi-admin\n    role: custodian'),
    );
    expect('role: custodian'.allMatches(yaml).length, networkRev4.views.length);
  });

  testWidgets('a schema without a connected custodian links to the guide, which can connect an idle plug', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero, noCustodian: true)),
        initialRoute: const SchemasRoute(),
      ),
    );
    await tester.pumpAndSettle();

    // Only telemetry lacks a custodian; its "Missing" badge opens the guide.
    final badge = find.byTooltip('How to connect a custodian snap');
    expect(badge, findsOneWidget);
    expect(find.text('How to connect?'), findsNothing, reason: 'no separate link');
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(find.textContaining('view: telemetry/telemetry-admin'), findsOneWidget);
    expect(find.textContaining('telemetry-agent:telemetry-admin'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('How to connect a custodian snap'), findsNothing);
  });
}
