import 'package:confdb_studio/theme/app_theme.dart';
import 'package:confdb_studio/widgets/common.dart';
import 'package:confdb_studio/widgets/copyable_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('confirmations with an action hide on their own', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showConfirmation(ctx, const Text('Change #1846 applied'), actionLabel: 'View', onAction: () {});
    await tester.pumpAndSettle();
    expect(find.text('Change #1846 applied'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget, reason: 'can also be dismissed early');

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Change #1846 applied'), findsNothing);
  });

  testWidgets('copyable text puts the path on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: Center(child: CopyableText('acme/network/wifi-admin', what: 'view path')),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Copy view path'));
    await tester.pump();
    expect(copied, 'acme/network/wifi-admin');
    expect(find.byTooltip('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
