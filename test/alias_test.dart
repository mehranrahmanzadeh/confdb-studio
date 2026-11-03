import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/storage_edit.dart';
import 'package:confdb_studio/screens/schema_editor/storage_pane.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('storage aliases', () {
    Future<void> openEditor(WidgetTester tester, {Size size = const Size(1440, 900), bool emptyStorage = false}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
      if (emptyStorage) {
        await repository.saveDraft(
          networkDraft.copyWith(
            storage: const StorageNode.root([]),
            views: const [],
            aliases: const {
              'network-connection-name': StorageNode(key: 'network-connection-name', kind: StorageKind.string, pattern: r'^[a-z0-9-]+$'),
            },
          ),
        );
      }
      await tester.pumpWidget(ConfdbStudioApp(repository: repository, initialRoute: const SchemaEditorRoute(networkId)));
      await tester.pumpAndSettle();
    }

    Future<void> selectTab(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(of: find.byType(StoragePane), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    Future<void> createAlias(WidgetTester tester, {required String name}) async {
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), name);
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
    }

    testWidgets('creating an alias from the tree opens the aliases tab', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      expect(find.text('channel-name'), findsOneWidget);
      expect(find.text('Aliases'), findsOneWidget);
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.aliases);
      expect(find.byTooltip('Actions for wifi.ssid'), findsNothing);
    });

    testWidgets('a storage path can be created from an existing alias', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      await selectTab(tester, 'Tree');

      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'band-name');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('channel-name').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('band-name'), findsOneWidget);
      // The new node is shown with the alias's name as its type.
      expect(find.text('channel-name'), findsOneWidget);
    });

    testWidgets('deleting an alias still referenced by a storage path is blocked', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      await selectTab(tester, 'Tree');
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add storage path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'band-name');
      await tester.tap(find.widgetWithText(TextField, 'Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('channel-name').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      await selectTab(tester, 'Aliases');
      await tester.tap(find.byTooltip('Actions for alias channel-name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Can’t delete alias'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // The alias is still there, untouched.
      expect(find.text('channel-name'), findsOneWidget);
    });

    testWidgets('aliases have an empty state and are hidden from the tree', (tester) async {
      await openEditor(tester);
      await selectTab(tester, 'Aliases');
      expect(find.text('No aliases yet.'), findsOneWidget);
      expect(find.byTooltip('Actions for wifi.ssid'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Create an alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), 'channel-name');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Actions for alias channel-name'), findsOneWidget);

      await selectTab(tester, 'Tree');
      expect(find.byTooltip('Actions for alias channel-name'), findsNothing);
      expect(find.byTooltip('Actions for wifi.ssid'), findsOneWidget);
      await selectTab(tester, 'Aliases');
      expect(find.byTooltip('Actions for alias channel-name'), findsOneWidget);
    });

    testWidgets('aliases remain editable and can be deleted from their tab', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      await tester.tap(find.byTooltip('Actions for alias channel-name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), 'network-name');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Actions for alias channel-name'), findsNothing);
      expect(find.byTooltip('Actions for alias network-name'), findsOneWidget);

      await tester.tap(find.byTooltip('Actions for alias network-name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete alias'));
      await tester.pumpAndSettle();
      expect(find.text('No aliases yet.'), findsOneWidget);
    });

    testWidgets('the aliases tab header can create an alias', (tester) async {
      await openEditor(tester);
      await selectTab(tester, 'Aliases');
      await tester.tap(find.byTooltip('Create an alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), 'channel-name');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Actions for alias channel-name'), findsOneWidget);
    });

    testWidgets('JSON edits are reflected in the aliases tab', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      await selectTab(tester, 'JSON');
      final json = find.byWidgetPredicate((w) => w is TextField && (w.controller?.text.contains('"channel-name"') ?? false));
      expect(json, findsOneWidget);
      final content = tester.widget<TextField>(json).controller!.text;
      await tester.enterText(json, content.replaceAll('"channel-name"', '"network-name"'));
      await tester.pumpAndSettle();
      await selectTab(tester, 'Aliases');
      expect(find.byTooltip('Actions for alias network-name'), findsOneWidget);
      expect(find.byTooltip('Actions for alias channel-name'), findsNothing);
    });

    testWidgets('Ctrl+F returns from aliases to the storage tree search', (tester) async {
      await openEditor(tester);
      await selectTab(tester, 'Aliases');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    });

    testWidgets('Ctrl+F works after creating an alias', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    });

    testWidgets('Ctrl+F works after switching from a focused storage search', (tester) async {
      await openEditor(tester);
      final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
      await tester.enterText(search, 'wifi');
      await tester.pumpAndSettle();
      await selectTab(tester, 'Aliases');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    });

    testWidgets('Ctrl+F works after opening aliases from the navigation rail', (tester) async {
      await openEditor(tester);
      final railFocus = Focus.of(tester.element(find.text('Data')));
      railFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(railFocus.hasPrimaryFocus, isTrue);
      await selectTab(tester, 'Aliases');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    });

    testWidgets('Ctrl+F works after creating an alias from the navigation rail', (tester) async {
      await openEditor(tester);
      final railFocus = Focus.of(tester.element(find.text('Data')));
      railFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(railFocus.hasPrimaryFocus, isTrue);
      await createAlias(tester, name: 'channel-name');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    });

    testWidgets('showing a lint path returns from aliases to the storage tree', (tester) async {
      await openEditor(tester);
      await selectTab(tester, 'Aliases');
      final lintList = find.ancestor(of: find.text('Go to rule'), matching: find.byType(ListView));
      await tester.scrollUntilVisible(
        find.text('Show in storage'),
        80,
        scrollable: find.descendant(of: lintList, matching: find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show in storage'));
      await tester.pumpAndSettle();
      expect(tester.widget<StoragePane>(find.byType(StoragePane)).tab, StoragePaneTab.tree);
      expect(find.byTooltip('Actions for proxy.https'), findsOneWidget);
    });

    testWidgets('the aliases tab is available in compact mode', (tester) async {
      await openEditor(tester, size: const Size(960, 1480));
      await tester.tap(find.text('Storage'));
      await tester.pumpAndSettle();
      await selectTab(tester, 'Aliases');
      expect(find.text('No aliases yet.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Create an alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), 'channel-name');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Actions for alias channel-name'), findsOneWidget);
      await selectTab(tester, 'Tree');
      expect(find.byTooltip('Actions for alias channel-name'), findsNothing);
      expect(find.byTooltip('Actions for wifi.ssid'), findsOneWidget);
    });

    testWidgets('all storage tabs fit at the minimum pane width', (tester) async {
      await openEditor(tester, emptyStorage: true);
      final semantics = tester.ensureSemantics();
      try {
        final tabs = find.byWidgetPredicate((w) => w is SegmentedButton<StoragePaneTab>);
        expect(tester.widget<SegmentedButton<StoragePaneTab>>(tabs).showSelectedIcon, isTrue);
        for (final tab in ['Tree', 'Aliases', 'JSON']) {
          await selectTab(tester, tab);
          await tester.drag(find.bySemanticsLabel('Resize storage panel'), const Offset(2000, 0), kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          expect(tester.getSize(find.byType(StoragePane)).width, 280, reason: '$tab minimum width');
          expect(tester.widget<SegmentedButton<StoragePaneTab>>(tabs).showSelectedIcon, isFalse);
          final label = find.descendant(of: find.byType(StoragePane), matching: find.text(tab));
          expect(tester.getSemantics(label), isSemantics(label: tab, isSelected: true, isButton: true));
          expect(tester.takeException(), isNull, reason: '$tab at the minimum pane width');
        }
      } finally {
        semantics.dispose();
      }
    });

    test('validateAliasName requires a leading letter and rejects duplicates', () {
      expect(validateAliasName('channel', const []), isNull);
      expect(validateAliasName('1channel', const []), isNotNull);
      expect(validateAliasName('channel', const ['channel']), isNotNull);
      expect(validateAliasName('Channel', const []), isNotNull);
    });
  });
}
