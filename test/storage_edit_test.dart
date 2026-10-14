import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/analysis.dart';
import 'package:confdb_studio/domain/storage_edit.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('storage edits', () {
    final root = networkRev4.storage;

    test('replace keeps the node in place', () {
      const band = StorageNode(key: 'band', kind: StorageKind.int, min: 1);
      final next = replaceAt(root, 'wifi.band', band);
      expect(next.lookup('wifi')!.children.map((c) => c.key), ['ssid', 'psk', 'band', 'status']);
      expect(next.lookup('wifi.band')!.kind, StorageKind.int);
    });

    test('remove drops a leaf or a whole map', () {
      expect(removeAt(root, 'wifi.status').lookup('wifi.status'), isNull);
      expect(removeAt(root, 'proxy').lookup('proxy'), isNull);
      expect(removeAt(root, 'proxy').lookup('wifi.ssid'), isNotNull);
    });

    test('renaming a path moves the rules that use it', () {
      final views = renameStorage(networkRev4.views, 'wifi.band', 'wifi.frequency');
      expect(views.expand((v) => v.rules).where((r) => r.storage == 'wifi.frequency').length, 2);
      expect(views.expand((v) => v.rules).where((r) => r.storage == 'wifi.band'), isEmpty);
    });

    test('keys are validated against their siblings', () {
      expect(validateStorageKey('band', siblingKeys(root, 'wifi')), isNotNull);
      expect(validateStorageKey('Band', const []), isNotNull);
      expect(validateStorageKey('channel', siblingKeys(root, 'wifi')), isNull);
    });
  });

  group('schema editor storage pane', () {
    Future<void> openEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ConfdbStudioApp(
          repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
          initialRoute: const SchemaEditorRoute(networkId),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('adds an enum path with its choices', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'security');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('enum').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Choices'), 'wpa2, wpa3, open');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('security'), findsOneWidget);
      expect(find.textContaining('wpa2 | wpa3 | open'), findsOneWidget);
    });

    testWidgets('psk is marked secret', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Actions for wifi.psk'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final secret = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Secret'));
      expect(secret.value, isTrue);
    });

    testWidgets('renaming keeps rules pointing at the path', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Actions for wifi.band'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'frequency');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('wifi.frequency'), findsWidgets, reason: 'the rules table and the views tree follow the rename');
      // Renaming introduces no new lint error (only the draft's existing signal one).
      expect(find.textContaining('storage path `wifi.band` does not exist'), findsNothing);
    });
  });

  test('the draft lint still sees only its original error after edits', () {
    final issues = lintSchema(networkDraft.copyWith(views: renameStorage(networkDraft.views, 'wifi.band', 'wifi.band')));
    expect(issues.where((i) => i.isError).length, 1);
  });
}
