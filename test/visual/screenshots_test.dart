// Renders screens to PNGs for visual review against the design files.
// Off by default. Run with:
//   flutter test test/visual --update-goldens --dart-define=SCREENSHOTS=/abs/out/dir
import 'dart:io';

import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shots.dart';

const _outDir = String.fromEnvironment('SCREENSHOTS');

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Ubuntu Sans');
  final mono = FontLoader('Ubuntu Sans Mono');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    sans.addFont(bytes('assets/fonts/UbuntuSans-$w.ttf'));
  }
  for (final w in ['Regular', 'Medium', 'SemiBold']) {
    mono.addFont(bytes('assets/fonts/UbuntuSansMono-$w.ttf'));
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'));
  final arrows = FontLoader('Confdb Arrows')..addFont(bytes('assets/fonts/ConfdbArrows.ttf'));
  await Future.wait([sans.load(), mono.load(), icons.load(), arrows.load()]);
}

void main() {
  setUpAll(_loadFonts);

  for (final shot in shots) {
    testWidgets(shot.name, skip: _outDir.isEmpty, (tester) async {
      tester.view.physicalSize = shot.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = FakeConfdbRepository(scenario: shot.scenario);
      if (shot.setup != null) await tester.runAsync(() => shot.setup!(repo));
      await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: shot.route));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (shot.act != null) {
        await shot.act!(tester);
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(Uri.file('$_outDir/${shot.name}.png')));
      // Let SnackBars, slow fake loads and their follow-ups finish.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 10));
      }
    });
  }
}

class Shot {
  const Shot(
    this.name,
    this.route, {
    this.size = const Size(1440, 900),
    this.scenario = const FakeScenario(latency: Duration.zero),
    this.act,
    this.setup,
  });
  final String name;
  final AppRoute route;
  final Size size;
  final FakeScenario scenario;
  final Future<void> Function(WidgetTester tester)? act;

  /// Prepares the sample backend before the app starts.
  final Future<void> Function(FakeConfdbRepository repo)? setup;
}
