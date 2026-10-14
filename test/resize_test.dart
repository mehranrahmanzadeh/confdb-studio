import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/screens/schema_editor/storage_pane.dart';
import 'package:confdb_studio/screens/schema_editor/views_pane.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:confdb_studio/widgets/resize_handle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  double viewsWidth(WidgetTester t) => t.getSize(find.byType(ViewsPane)).width;
  double storageWidth(WidgetTester t) => t.getSize(find.byType(StoragePane)).width;

  testWidgets('dragging the dividers resizes the side panes', (tester) async {
    await openEditor(tester);
    expect(viewsWidth(tester), 260);
    expect(storageWidth(tester), 340);

    await tester.drag(find.bySemanticsLabel('Resize views panel'), const Offset(80, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(viewsWidth(tester), 340);

    await tester.drag(find.bySemanticsLabel('Resize storage panel'), const Offset(-100, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(storageWidth(tester), 440);
  });

  testWidgets('the middle column keeps its minimum width', (tester) async {
    await openEditor(tester);
    await tester.drag(find.bySemanticsLabel('Resize storage panel'), const Offset(-2000, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final handles = find.byType(ResizeHandle);
    final middle = tester.getTopLeft(handles.last).dx - tester.getTopRight(handles.first).dx;
    expect(middle, greaterThanOrEqualTo(380));
  });

  testWidgets('keyboard arrows and double-click reset', (tester) async {
    await openEditor(tester);
    final handle = find.byType(ResizeHandle).first;
    await tester.tap(handle);
    final focus = Focus.of(tester.element(find.descendant(of: handle, matching: find.byType(Tooltip))));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(viewsWidth(tester), 276);

    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(viewsWidth(tester), 260);
  });
}
