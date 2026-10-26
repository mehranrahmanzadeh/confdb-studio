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

    test('a field can be added, edited and removed inside an array\'s map element', () {
      final withDevices = root.insert(
        'devices',
        const StorageNode(key: 'devices', kind: StorageKind.array).withElement(const StorageNode(key: '', kind: StorageKind.map)),
      );
      // Adding a field under `devices[{n}]` works like any other map.
      expect(mapPaths(withDevices), contains('devices[{n}]'));
      final withName = withDevices.insert('devices[{n}].name', const StorageNode(key: 'name', kind: StorageKind.string));
      expect(withName.lookup('devices[{n}].name')!.kind, StorageKind.string);
      expect(siblingKeys(withName, 'devices[{n}]'), ['name']);
      // Editing it in place keeps it under the element.
      final edited = replaceAt(withName, 'devices[{n}].name', const StorageNode(key: 'name', kind: StorageKind.int));
      expect(edited.lookup('devices[{n}].name')!.kind, StorageKind.int);
      // Removing it leaves the element an empty map.
      final removed = removeAt(withName, 'devices[{n}].name');
      expect(removed.lookup('devices[{n}].name'), isNull);
      expect(removed.lookup('devices[{n}]'), isNotNull);
      // Removing the whole array drops it and its element.
      expect(removeAt(withName, 'devices').lookup('devices'), isNull);
    });
  });

  group('schema editor storage pane', () {
    Future<FakeConfdbRepository> openEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
      await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemaEditorRoute(networkId)));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('adds a string path restricted to fixed choices', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'security');
      await tester.tap(find.widgetWithText(SwitchListTile, 'Fixed choices'));
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

    testWidgets('adds an array of maps and lets fields be added inside each element', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'devices');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('array').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'Element type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('map').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Unique'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('devices'), findsOneWidget);
      // The element appears as its own row, offering only to add fields inside it.
      await tester.ensureVisible(find.byTooltip('Actions for devices[{n}]'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actions for devices[{n}]'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.text('Add child'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'name');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('name'), findsOneWidget);
    });

    testWidgets('restricts an array\'s scalar elements to a pattern or fixed choices', (tester) async {
      final repo = await openEditor(tester);

      // A string array can restrict each element with a pattern.
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'urls');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('array').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Pattern (optional)'), r'^https?://');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('urls'), findsOneWidget);

      // A number array can restrict each element to fixed choices instead of min/max.
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'rates');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('array').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'Element type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('number').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Fixed choices'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Choices'), '100, 500, 800');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('rates'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 500)); // draft autosave
      final draft = (await tester.runAsync(repo.listDrafts))!.singleWhere((d) => d.id == networkId);
      final urls = draft.storage.lookup('urls')!;
      expect(urls.pattern, isNull, reason: 'the pattern belongs to the element, not the array itself');
      expect(urls.element!.pattern, r'^https?://');
      final rates = draft.storage.lookup('rates')!;
      expect(rates.element!.choices, ['100', '500', '800']);
    });
  });

  test('the draft lint still sees only its original error after edits', () {
    final issues = lintSchema(networkDraft.copyWith(views: renameStorage(networkDraft.views, 'wifi.band', 'wifi.band')));
    expect(issues.where((i) => i.isError).length, 1);
  });
}
