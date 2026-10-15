import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:confdb_studio/widgets/account_name.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? copied;

  Future<void> open(WidgetTester tester, AppRoute route) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    copied = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
        initialRoute: route,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the schemas list names the account by its alias; hover shows the ID, a click copies it', (tester) async {
    await open(tester, const SchemasRoute());
    expect(find.textContaining(acmeAccountId), findsNothing);
    final name = find.descendant(of: find.byType(AccountName), matching: find.text('acme'));
    expect(name, findsOneWidget);
    expect(find.byTooltip(RegExp('Account ID: $acmeAccountId')), findsOneWidget);
    await tester.tap(name);
    await tester.pump();
    expect(copied, acmeAccountId);
    expect(find.byTooltip('Copied account ID'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a view path shows the alias but copies the real path', (tester) async {
    await open(tester, const SchemaEditorRoute(networkId, view: 'wifi-admin'));
    expect(find.text('acme/network/wifi-admin'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy view path'));
    await tester.pump();
    expect(copied, '$acmeAccountId/network/wifi-admin');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('sentences use the alias; commands keep the ID', (tester) async {
    await open(tester, const DataRoute(view: ViewRef(acmeAccountId, 'network', 'wifi-admin'), key: 'ssid'));
    expect(find.textContaining('acme/network/wifi-admin'), findsWidgets);
    await tester.tap(find.text('CLI').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('$acmeAccountId/network/wifi-admin', findRichText: true), findsWidgets);
  });
}
