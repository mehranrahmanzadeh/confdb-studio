import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:confdb_studio/widgets/app_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
        initialRoute: const SchemaEditorRoute(networkId, view: 'wifi-state'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addMapWithChildren(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add storage path or alias'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add storage path'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'device');
    await tester.tap(find.widgetWithText(TextField, 'Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    for (final key in ['name', 'id']) {
      await tester.ensureVisible(find.byTooltip('Actions for device'));
      await tester.tap(find.byTooltip('Actions for device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add child'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), key);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('a rule to a map lets a subset of its fields be exposed via content', (tester) async {
    await openEditor(tester);
    await addMapWithChildren(tester);

    await tester.ensureVisible(find.text('Add rule'));
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();

    final request = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'request');
    await tester.enterText(request, 'device');
    await tester.pumpAndSettle();
    final storage = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'storage.path');
    await tester.enterText(storage, 'device');
    await tester.pumpAndSettle();
    // Un-focus the field to close the storage-path autocomplete popup, without
    // letting it auto-select a suggestion over the typed value.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // The storage path resolves to a map, so a subset of its fields can be picked
    // from the "Fields" dropdown, which defaults to "All fields".
    expect(find.text('All fields'), findsOneWidget);
    await tester.tap(find.text('All fields'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'name'));
    await tester.pumpAndSettle();
    // Closing the dropdown (tap outside) applies the selection.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // The rule stays a single row pointing at the whole map; only the
    // dropdown's selection (its `content`) narrows what's exposed.
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'device'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, 'name'), findsOneWidget);
    expect(find.text('All fields'), findsNothing);

    // Reopening the dropdown still shows the selection ticked.
    await tester.tap(find.widgetWithText(OutlinedButton, 'name'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MenuItemButton), matching: find.byIcon(AppIcons.check)), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
  });

  testWidgets('dragging a rule\'s handle reorders it within the view', (tester) async {
    await openEditor(tester);

    List<String> orderedRequests() => [
      for (final e in find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request').evaluate())
        (e.widget as TextField).controller!.text,
    ];
    expect(orderedRequests(), ['ssid', 'band', 'status']);

    final ssidHandle = tester.getCenter(find.bySemanticsLabel('Reorder rule ssid'));
    final statusHandle = tester.getCenter(find.bySemanticsLabel('Reorder rule status'));
    // Drag the first rule ("ssid") below the last one ("status"). A pump for
    // kPressTimeout after the initial touch lets the recognizer register the
    // drag start before moving, matching ReorderableListView's own tests.
    final gesture = await tester.startGesture(ssidHandle);
    await tester.pump(kPressTimeout);
    // Step the drag down through each row so ReorderableListView re-evaluates
    // the drop position after every intermediate move, not just the final one.
    final steps = (statusHandle.dy - ssidHandle.dy).abs() / 10;
    for (var s = 1; s <= steps; s++) {
      await gesture.moveTo(Offset(ssidHandle.dx, ssidHandle.dy + s * 10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.moveTo(statusHandle + const Offset(0, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(orderedRequests(), ['band', 'status', 'ssid']);
    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
  });
}
