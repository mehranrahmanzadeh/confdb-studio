import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/domain/storage_edit.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('storage aliases', () {
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

    Future<void> createAlias(WidgetTester tester, {required String name}) async {
      await tester.tap(find.byTooltip('Add storage path or alias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Alias name'), name);
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
    }

    testWidgets('creates an alias and shows it in the aliases section', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
      expect(find.text('channel-name'), findsOneWidget);
      expect(find.text('Aliases'), findsOneWidget);
    });

    testWidgets('a storage path can be created from an existing alias', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');

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
      expect(find.text('channel-name'), findsWidgets);
    });

    testWidgets('deleting an alias still referenced by a storage path is blocked', (tester) async {
      await openEditor(tester);
      await createAlias(tester, name: 'channel-name');
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

      await tester.tap(find.byTooltip('Actions for alias channel-name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Can’t delete alias'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // The alias is still there, untouched.
      expect(find.text('channel-name'), findsWidgets);
    });

    test('validateAliasName requires a leading letter and rejects duplicates', () {
      expect(validateAliasName('channel', const []), isNull);
      expect(validateAliasName('1channel', const []), isNotNull);
      expect(validateAliasName('channel', const ['channel']), isNotNull);
      expect(validateAliasName('Channel', const []), isNotNull);
    });
  });
}
