import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/analysis.dart';
import 'package:confdb_studio/screens/schema_editor/rule_cards.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:confdb_studio/theme/app_theme.dart';
import 'package:confdb_studio/widgets/app_icons.dart';
import 'package:confdb_studio/widgets/code_text.dart';
import 'package:confdb_studio/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = StorageNode.root([
    StorageNode(
      key: 'device',
      kind: StorageKind.map,
      children: [
        StorageNode(key: 'name', kind: StorageKind.string),
        StorageNode(key: 'id', kind: StorageKind.string),
      ],
    ),
    StorageNode(key: 'serial', kind: StorageKind.string),
  ]);
  const initialRules = [
    ViewRule(request: 'device', storage: 'device', access: RuleAccess.readWrite),
    ViewRule(request: 'serial', storage: 'serial', access: RuleAccess.read),
  ];

  Future<void> pumpCards(
    WidgetTester tester, {
    double width = 480,
    double textScale = 1,
    List<ViewRule> startingRules = initialRules,
    List<LintIssue> issues = const [],
    String? focusRule,
    String? selectedStoragePath,
    ValueChanged<String>? onStoragePathSelected,
    void Function(String, StorageNode)? onQuickFix,
  }) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var rules = startingRules;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (context, setState) => RuleCards(
                    view: ViewDef(name: 'test-view', rules: rules),
                    storage: storage,
                    usage: const {},
                    issues: issues,
                    focusRule: focusRule,
                    selectedStoragePath: selectedStoragePath,
                    onStoragePathSelected: onStoragePathSelected ?? (_) {},
                    onChanged: (updated) => setState(() => rules = updated),
                    onQuickFix: onQuickFix ?? (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester, {Size size = const Size(1440, 2400)}) async {
    tester.view.physicalSize = size;
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

  testWidgets('each rule card places its path fields above the dropdowns', (tester) async {
    for (final width in [360.0, 480.0, 800.0]) {
      for (final textScale in [1.0, 1.3]) {
        await pumpCards(tester, width: width, textScale: textScale);
        expect(tester.takeException(), isNull, reason: 'width $width, text scale $textScale');
        expect(find.byType(SectionCard), findsNWidgets(2));
        expect(find.text('Request path'), findsNWidgets(2));
        expect(find.text('Storage path'), findsNWidgets(2));
        expect(find.text('Fields'), findsOneWidget);
        expect(find.text('Access'), findsNWidgets(2));

        final request = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'request' && w.controller?.text == 'device',
        );
        final card = find.ancestor(of: request, matching: find.byType(SectionCard));
        final storageField = find.descendant(
          of: card,
          matching: find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'storage.path'),
        );
        final arrow = find.descendant(of: card, matching: find.byIcon(AppIcons.next));
        final fields = find.descendant(of: card, matching: find.widgetWithText(OutlinedButton, 'All fields'));
        final access = find.descendant(of: card, matching: find.widgetWithText(OutlinedButton, 'read-write'));
        final requestRect = tester.getRect(request);
        final storageRect = tester.getRect(storageField);
        final arrowRect = tester.getRect(arrow);
        final fieldsRect = tester.getRect(fields);
        final accessRect = tester.getRect(access);
        expect(storageRect.top, moreOrLessEquals(requestRect.top, epsilon: 0.1));
        expect(requestRect.right, lessThanOrEqualTo(arrowRect.left));
        expect(arrowRect.right, lessThanOrEqualTo(storageRect.left));
        expect(arrowRect.center.dy, inInclusiveRange(requestRect.top, requestRect.bottom));
        expect(fieldsRect.top, greaterThan(storageRect.bottom));
        expect(accessRect.top, moreOrLessEquals(fieldsRect.top, epsilon: 0.1));
        expect(fieldsRect.right, lessThan(accessRect.left));
      }
    }
  });

  testWidgets('card controls edit paths, fields and access and can delete a rule', (tester) async {
    final selectedPaths = <String>[];
    await pumpCards(tester, onStoragePathSelected: selectedPaths.add);

    await tester.tap(find.widgetWithText(OutlinedButton, 'read-write'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'write'));
    await tester.pumpAndSettle();
    expect(tester.widget<RuleCards>(find.byType(RuleCards)).view.rules.first.access, RuleAccess.write);

    await tester.tap(find.widgetWithText(OutlinedButton, 'All fields'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'name'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(tester.widget<RuleCards>(find.byType(RuleCards)).view.rules.first.content, [const ContentField(key: 'name')]);

    final request = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request').first;
    await tester.enterText(request, 'renamed');
    await tester.pumpAndSettle();
    final storageField = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'storage.path').first;
    await tester.enterText(storageField, 'device.name');
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final edited = tester.widget<RuleCards>(find.byType(RuleCards)).view.rules.first;
    expect(edited.request, 'renamed');
    expect(edited.storage, 'device.name');
    expect(selectedPaths.last, 'device.name');
    expect(find.text('Fields'), findsNothing);

    await tester.tap(find.byTooltip('Delete rule renamed · Ctrl+Backspace'));
    await tester.pumpAndSettle();
    expect(tester.widget<RuleCards>(find.byType(RuleCards)).view.rules.single.request, 'serial');
  });

  testWidgets('card controls have accessible rule and field labels', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCards(tester);

    expect(find.bySemanticsLabel(RegExp(r'^Rule device\b')), findsOneWidget);
    expect(find.bySemanticsLabel('Reorder rule device'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Storage path for device')), findsOneWidget);
    expect(find.bySemanticsLabel('Access for device: read-write'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('selecting storage highlights the matching card', (tester) async {
    await pumpCards(tester, selectedStoragePath: 'device.name');
    final cards = tester.widgetList<SectionCard>(find.byType(SectionCard)).toList();
    expect(cards.first.color, isNotNull);
    expect(cards.last.color, isNull);
  });

  testWidgets('an empty view can add a focused rule card', (tester) async {
    await pumpCards(tester, startingRules: const []);
    expect(find.textContaining('No rules yet'), findsOneWidget);
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No rules yet'), findsNothing);
    final request = tester.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request'));
    expect(request.focusNode!.hasFocus, isTrue);
    expect(find.text('Request path'), findsOneWidget);
    expect(find.text('Storage path'), findsOneWidget);
  });

  testWidgets('a card keeps inline errors and the storage quick fix', (tester) async {
    const leaf = StorageNode(key: 'missing', kind: StorageKind.string);
    String? fixedPath;
    StorageNode? fixedLeaf;
    await pumpCards(
      tester,
      width: 360,
      textScale: 1.3,
      focusRule: 'lost',
      startingRules: const [ViewRule(request: 'lost', storage: 'device.missing', access: RuleAccess.read)],
      issues: const [
        LintIssue(
          severity: LintSeverity.error,
          message: 'Missing storage',
          request: 'lost',
          storagePath: 'device.missing',
          suggestedLeaf: leaf,
        ),
      ],
      onQuickFix: (path, node) {
        fixedPath = path;
        fixedLeaf = node;
      },
    );
    expect(find.byWidgetPredicate((w) => w is CodeText && w.text.contains('does not exist in storage')), findsOneWidget);
    final storageField = tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'storage.path'),
    );
    expect(storageField.focusNode!.hasFocus, isTrue);
    expect(tester.widget<SectionCard>(find.byType(SectionCard)).color, isNotNull);
    await tester.tap(find.text('Add device.missing (string) to storage'));
    await tester.pumpAndSettle();
    expect(fixedPath, 'device.missing');
    expect(fixedLeaf, leaf);
  });

  testWidgets('lint navigation brings an off-screen rule card into view', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    final admin = networkDraft.views.firstWhere((view) => view.name == 'wifi-admin');
    final signal = admin.rules.firstWhere((rule) => rule.request == 'signal');
    await repo.saveDraft(
      networkDraft.copyWith(
        views: [
          for (final view in networkDraft.views)
            if (view.name == admin.name) view.copyWith(rules: [...admin.rules.where((rule) => rule != signal), signal]) else view,
        ],
      ),
    );
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: repo,
        initialRoute: const SchemaEditorRoute(networkId, view: 'wifi-admin'),
      ),
    );
    await tester.pumpAndSettle();

    final storageField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'storage.path' && w.controller?.text == 'wifi.signal',
    );
    final lintHeader = find.text('Lint');
    expect(tester.getTopLeft(storageField).dy, greaterThan(tester.getTopLeft(lintHeader).dy));
    await tester.tap(find.text('Go to rule').first);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(storageField).focusNode!.hasFocus, isTrue);
    final card = find.ancestor(of: storageField, matching: find.byType(SectionCard));
    expect(tester.getBottomLeft(card).dy, lessThan(tester.getTopLeft(lintHeader).dy));
  });

  testWidgets('adding a rule brings the complete new card into view', (tester) async {
    await openEditor(tester, size: const Size(1440, 900));
    await tester.ensureVisible(find.text('Add rule'));
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();

    final request = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request' && w.controller?.text == '');
    expect(tester.widget<TextField>(request).focusNode!.hasFocus, isTrue);
    final card = find.ancestor(of: request, matching: find.byType(SectionCard));
    expect(tester.getBottomLeft(card).dy, lessThan(tester.getTopLeft(find.text('Lint')).dy));
  });

  testWidgets('the add-rule shortcut reveals the new card from the storage pane', (tester) async {
    await openEditor(tester, size: const Size(1440, 900));
    final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
    await tester.tap(search);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'R');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final request = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request' && w.controller?.text == '');
    expect(tester.widget<TextField>(request).focusNode!.hasFocus, isTrue);
    final card = find.ancestor(of: request, matching: find.byType(SectionCard));
    expect(tester.getBottomLeft(card).dy, lessThan(tester.getTopLeft(find.text('Lint')).dy));
  });

  testWidgets('storage path actions do not include view shortcuts', (tester) async {
    await openEditor(tester);
    await tester.ensureVisible(find.byTooltip('Actions for wifi.ssid'));
    await tester.tap(find.byTooltip('Actions for wifi.ssid'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.textContaining('Expose in '), findsNothing);
    expect(find.textContaining('Open in '), findsNothing);
  });

  testWidgets('storage search filters paths and Ctrl+F focuses it', (tester) async {
    await openEditor(tester);
    final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search storage paths');
    await tester.enterText(search, 'wifi.band');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Actions for wifi.band'), findsOneWidget);
    expect(find.byTooltip('Actions for wifi.ssid'), findsNothing);

    await tester.tap(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request').first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
  });

  testWidgets('keyboard shortcuts add, reorder and delete a rule', (tester) async {
    await openEditor(tester);
    List<TextField> requestFields() =>
        tester.widgetList<TextField>(find.byType(TextField)).where((field) => field.decoration?.hintText == 'request').toList();
    final initial = requestFields().map((field) => field.controller!.text).toList();

    await tester.tap(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request').first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'R');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(requestFields(), hasLength(initial.length + 1));

    await tester.tap(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'request').first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(requestFields().first.controller!.text, initial[1]);
    expect(requestFields()[1].controller!.text, initial[0]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(requestFields(), hasLength(initial.length));
  });

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

    // The rule stays a single card pointing at the whole map; only the
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

  testWidgets('a nested map field lets a subset of its own fields be exposed, arbitrarily deep', (tester) async {
    await openEditor(tester);
    await addMapWithChildren(tester);

    // Turn 'id' into a nested map with its own child, so the fields dropdown
    // has to offer a second level of selection.
    await tester.ensureVisible(find.byTooltip('Actions for device.id'));
    await tester.tap(find.byTooltip('Actions for device.id'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Actions for device.id'));
    await tester.tap(find.byTooltip('Actions for device.id'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add child'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'tag');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
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

    await tester.tap(find.text('All fields'));
    await tester.pumpAndSettle();
    // 'id' is itself a map, so it's a submenu rather than a plain checkbox item.
    expect(find.widgetWithText(SubmenuButton, 'id'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'id'), findsNothing);
    await tester.tap(find.widgetWithText(SubmenuButton, 'id'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'tag'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Only the nested field is exposed, as a dot-joined path.
    expect(find.widgetWithText(OutlinedButton, 'id.tag'), findsOneWidget);

    // Reopening shows 'id' as partially selected (its submenu's own row has
    // a dash, not a full check) and 'tag' itself ticked.
    await tester.tap(find.widgetWithText(OutlinedButton, 'id.tag'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(SubmenuButton), matching: find.byIcon(AppIcons.dash)), findsOneWidget);
    await tester.tap(find.widgetWithText(SubmenuButton, 'id'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MenuItemButton), matching: find.byIcon(AppIcons.check)), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
  });

  testWidgets('an array of maps lets a subset of its element\'s fields be exposed, as a single content entry', (tester) async {
    // Wider than the other tests: a map with an array-of-maps field hits an
    // unrelated storage-pane layout overflow (a type chip plus usage count)
    // at the narrower default width.
    await openEditor(tester, size: const Size(2600, 2400));

    // Add a map containing an array-of-maps field, with two fields inside
    // its element — mirroring a real rule nesting `content` under a map
    // field like `snaps[{n}]`.
    await tester.tap(find.byTooltip('Add storage path or alias'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add storage path'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'container');
    await tester.tap(find.widgetWithText(TextField, 'Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Actions for container'));
    await tester.tap(find.byTooltip('Actions for container'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add child'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    for (final key in ['name', 'id']) {
      await tester.ensureVisible(find.byTooltip('Actions for container.devices[{n}]'));
      await tester.tap(find.byTooltip('Actions for container.devices[{n}]'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add child'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Key'), key);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
    }

    await tester.ensureVisible(find.text('Add rule'));
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    final request = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'request');
    await tester.enterText(request, 'container');
    await tester.pumpAndSettle();
    final storage = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'storage.path');
    await tester.enterText(storage, 'container');
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await tester.tap(find.text('All fields'));
    await tester.pumpAndSettle();
    // The array's element is offered as a single submenu row, combining the
    // array's own key with the element marker (`devices[{n}]`), not as two
    // separate nested levels.
    expect(find.widgetWithText(SubmenuButton, 'devices[{n}]'), findsOneWidget);
    await tester.tap(find.widgetWithText(SubmenuButton, 'devices[{n}]'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'name'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'devices[{n}].name'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500)); // draft autosave
  });

  testWidgets("the storage path dropdown and selection show a map placeholder as '{placeholder}', not the internal {key} marker", (
    tester,
  ) async {
    await openEditor(tester);

    // A map with a placeholder (any key): "actuators.{placeholder}".
    await tester.tap(find.byTooltip('Add storage path or alias'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add storage path'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'actuators');
    await tester.tap(find.widgetWithText(TextField, 'Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions for actuators'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add placeholder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Value type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('string').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add rule'));
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    final storage = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText == 'storage.path');
    await tester.enterText(storage, 'actuators');
    await tester.pumpAndSettle();

    expect(find.textContaining('actuators.{placeholder}'), findsOneWidget);
    expect(find.textContaining('{key}'), findsNothing);

    await tester.tap(find.text('actuators.{placeholder}'));
    await tester.pumpAndSettle();

    final storageAfter = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'storage.path' && w.controller?.text == 'actuators.{placeholder}',
    );
    expect(storageAfter, findsOneWidget);
    expect((tester.widget(storageAfter) as TextField).controller?.text, 'actuators.{placeholder}');
    expect(find.textContaining('{key}'), findsNothing);

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
    // Step the drag down through each card so ReorderableListView re-evaluates
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
