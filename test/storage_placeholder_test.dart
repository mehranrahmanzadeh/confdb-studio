import 'dart:convert';

import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/analysis.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:confdb_studio/domain/storage_edit.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pattern = r'^[a-z](?:-?[a-z0-9])*$';

/// The `actuators` map from the robot example.
const _expected = {
  'type': 'map',
  'keys': {'type': 'string', 'pattern': _pattern},
  'values': {
    'schema': {
      'mode': {
        'type': 'string',
        'choices': ['manual', 'auto'],
      },
      'manual-speed': {'type': 'number', 'min': 0.1},
      'auto-max-speed': {'type': 'number', 'min': 0.1},
    },
  },
};

Object? _actuators(StorageNode root) => (encodeStorage(root)['storage']! as Map)['schema']['actuators'];

void main() {
  test('a placeholder with typed values and children encodes as keys + values', () {
    var root = const StorageNode.root([StorageNode(key: 'actuators', kind: StorageKind.map)]);
    final map = root
        .lookup('actuators')!
        .withElement(const StorageNode(key: StorageNode.placeholderKey, kind: StorageKind.map))
        .withKeys(const StorageNode(key: 'keys', kind: StorageKind.string, pattern: _pattern));
    root = replaceAt(root, 'actuators', map);
    root = root
        .insert('actuators.{key}.mode', const StorageNode(key: 'mode', kind: StorageKind.string, choices: ['manual', 'auto']))
        .insert('actuators.{key}.manual-speed', const StorageNode(key: 'manual-speed', kind: StorageKind.number, min: 0.1))
        .insert('actuators.{key}.auto-max-speed', const StorageNode(key: 'auto-max-speed', kind: StorageKind.number, min: 0.1));

    expect(_actuators(root), _expected);
    expect(
      [for (final (_, p, _) in root.walk()) p],
      ['actuators', 'actuators.{key}', 'actuators.{key}.mode', 'actuators.{key}.manual-speed', 'actuators.{key}.auto-max-speed'],
    );
    // Decoding gives the same tree back, and the rule from the example covers it.
    expect(_actuators(decodeStorage(jsonDecode(jsonEncode(encodeStorage(root)))).storage), _expected);
    expect(resolveStoragePath(root, 'actuators.{act}[.mode={mode}].manual-speed')?.min, 0.1);
    expect(ruleCovers('actuators.{act}[.mode={mode}].mode', 'actuators.{key}.mode'), isTrue);

    // Renaming a key under the placeholder follows into rules, keeping their names and filters.
    final views = renameStorage(
      [
        const ViewDef(
          name: 'actuator-admin',
          rules: [ViewRule(request: 'actuators.{act}.mode', storage: 'actuators.{act}[.mode={mode}].mode', access: RuleAccess.read)],
        ),
      ],
      'actuators.{key}.mode',
      'actuators.{key}.state',
    );
    expect(views.single.rules.single.storage, 'actuators.{act}[.mode={mode}].state');

    // Deleting the placeholder leaves an empty map, without keys.
    final emptied = removeAt(root, 'actuators.{key}').lookup('actuators')!;
    expect(emptied.hasPlaceholder, isFalse);
    expect(emptied.keys, isNull);
  });

  testWidgets('the storage tree adds a placeholder to an empty map, then children to it', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    const id = SchemaId('acme', 'bot');
    await tester.runAsync(
      () => repo.saveDraft(
        const ConfdbSchema(
          id: id,
          summary: '',
          storage: StorageNode.root([
            StorageNode(key: 'actuators', kind: StorageKind.map),
            StorageNode(key: 'name', kind: StorageKind.string),
          ]),
          views: [],
          isDraft: true,
        ),
      ),
    );
    await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemaEditorRoute(id)));
    await tester.pumpAndSettle();

    Future<void> menu(String path, String item) async {
      await tester.tap(find.byTooltip('Actions for $path'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    // Only an empty map offers it.
    await tester.tap(find.byTooltip('Actions for name'));
    await tester.pumpAndSettle();
    expect(find.text('Add placeholder'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await menu('actuators', 'Add placeholder');
    expect(find.text('Add placeholder to actuators'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Placeholder pattern (optional)'), _pattern);
    await tester.tap(find.widgetWithText(TextField, 'Value type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('<placeholder>'), findsOneWidget);
    expect(find.textContaining('keys match $_pattern'), findsOneWidget);

    await menu('actuators.{key}', 'Add child');
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'manual-speed');
    await tester.tap(find.widgetWithText(TextField, 'Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('number').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Min (optional)'), '0.1');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave

    final draft = (await tester.runAsync(repo.listDrafts))!.singleWhere((d) => d.id == id);
    expect(_actuators(draft.storage), {
      'type': 'map',
      'keys': {'type': 'string', 'pattern': _pattern},
      'values': {
        'schema': {
          'manual-speed': {'type': 'number', 'min': 0.1},
        },
      },
    });
  });

  testWidgets('a placeholder\'s key constraint can be an alias instead of a pattern', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    const id = SchemaId('acme', 'bot');
    await tester.runAsync(
      () => repo.saveDraft(
        const ConfdbSchema(
          id: id,
          summary: '',
          storage: StorageNode.root([StorageNode(key: 'actuators', kind: StorageKind.map)]),
          views: [],
          aliases: {'gadget-name': StorageNode(key: 'gadget-name', kind: StorageKind.string, pattern: _pattern)},
          isDraft: true,
        ),
      ),
    );
    await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemaEditorRoute(id)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions for actuators'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add placeholder'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Key type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gadget-name').last);
    await tester.pumpAndSettle();
    // The pattern field disappears: the key constraint comes from the alias.
    expect(find.widgetWithText(TextField, 'Placeholder pattern (optional)'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('keys match alias `gadget-name`'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
    final draft = (await tester.runAsync(repo.listDrafts))!.singleWhere((d) => d.id == id);
    expect(_actuators(draft.storage), {'type': 'map', 'keys': r'${gadget-name}', 'values': 'string'});
  });
}
