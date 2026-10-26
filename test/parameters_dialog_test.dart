import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/state/app_controller.dart';
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

  testWidgets('a parameter is declared via "Manage parameters" and assigned as a field filter on a rule', (tester) async {
    await openEditor(tester);
    await addMapWithChildren(tester);

    // Declare a parameter at the view level.
    await tester.tap(find.byTooltip('Manage parameters of wifi-state'));
    await tester.pumpAndSettle();
    expect(find.text('Parameters of "wifi-state"'), findsOneWidget);
    await tester.tap(find.text('New parameter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Parameter name'), 'device-name');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add rule'));
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();

    final request = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'request');
    await tester.enterText(request, 'device');
    await tester.pumpAndSettle();
    final storage = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'storage.path');
    await tester.enterText(storage, 'device');
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // The storage path resolves to a map, so the "filter by parameter" button is shown.
    await tester.ensureVisible(find.byTooltip('Filter device by parameter'));
    await tester.tap(find.byTooltip('Filter device by parameter'));
    await tester.pumpAndSettle();

    expect(find.text('Filter by parameter'), findsOneWidget);
    await tester.tap(find.text('Add filter'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownMenu<String>, 'Field'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'name'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownMenu<String>, 'Parameter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'device-name'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'device[.name={device-name}]'),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
  });

  testWidgets('the "filter by parameter" button only shows for rules whose storage path resolves to a map', (tester) async {
    await openEditor(tester);

    // "ssid" is a scalar leaf, not a map, so it has no filter-by-parameter button.
    expect(find.byTooltip('Filter wifi.ssid by parameter'), findsNothing);

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
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // "device" resolves to a map with children, so the button is shown.
    expect(find.byTooltip('Filter device by parameter'), findsOneWidget);
  });
}
