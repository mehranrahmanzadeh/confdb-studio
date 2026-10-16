import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/shell/account_button.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('clickable things show the hand cursor on desktop', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
        initialRoute: const OverviewRoute(),
      ),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    Future<MouseCursor?> cursorAt(Offset position) async {
      await mouse.moveTo(position);
      await tester.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    final clickable = {
      'rail destination': tester.getCenter(find.text('Data')),
      'rail destination padding': tester.getTopLeft(find.text('Data')) + const Offset(-14, -6),
      'account button': tester.getCenter(find.descendant(of: find.byType(AccountButton), matching: find.text('acme'))),
      'filled button': tester.getCenter(find.text('New schema')),
      'filter chip': tester.getCenter(find.textContaining('Drafts')),
      'icon button': tester.getCenter(find.byTooltip('Actions for acme/network')),
      'schema name link': tester.getCenter(find.text('telemetry')),
    };
    for (final MapEntry(:key, :value) in clickable.entries) {
      expect(await cursorAt(value), SystemMouseCursors.click, reason: key);
    }
    final railGap = Offset(tester.getCenter(find.text('Access')).dx, tester.getBottomLeft(find.text('Access')).dy + 120);
    expect(await cursorAt(railGap), isNot(SystemMouseCursors.click), reason: 'empty rail space');
    expect(
      await cursorAt(tester.getCenter(find.textContaining('on this device and in the Snap Store'))),
      isNot(SystemMouseCursors.click),
      reason: 'page subtitle',
    );
  });
}
