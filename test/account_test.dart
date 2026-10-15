import 'dart:io';

import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:confdb_studio/data/snapd/transport.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rail account button', () {
    Future<void> boot(WidgetTester tester, FakeScenario scenario) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ConfdbStudioApp(repository: FakeConfdbRepository(scenario: scenario)));
      await tester.pumpAndSettle();
    }

    testWidgets('warns and explains how to log in when snapcraft is logged out', (tester) async {
      await boot(tester, const FakeScenario(latency: Duration.zero, loggedOut: true));
      expect(find.text('Log in'), findsOneWidget);
      await tester.tap(find.text('Log in'));
      await tester.pumpAndSettle();
      expect(find.text('Warning · not logged in to snapcraft'), findsOneWidget);
      expect(find.text('snapcraft login'), findsOneWidget);
    });

    testWidgets('shows the username when logged in', (tester) async {
      await boot(tester, const FakeScenario(latency: Duration.zero));
      expect(find.text('Log in'), findsNothing);
      expect(find.byTooltip('Logged in to snapcraft as acme'), findsOneWidget);
    });
  });

  group('snapcraft whoami', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('whoami'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<StoreAccount> run(String script) async {
      final f = File('${dir.path}/snapcraft')..writeAsStringSync('#!/bin/sh\n$script\n');
      await Process.run('chmod', ['+x', f.path]);
      return SnapdRepository(SnapCommandTransport(), snapcraftCommand: f.path).storeAccount();
    }

    test('parses a logged-in account', () async {
      final a = await run("printf 'email: dev@example.com\\nusername: dev\\nid: AbC123\\npermissions: package_access\\n'");
      expect(a.isLoggedIn, isTrue);
      expect(a.username, 'dev');
      expect(a.email, 'dev@example.com');
      expect(a.accountId, 'AbC123');
    });

    test('reports logged out with snapcraft’s message', () async {
      final a = await run("echo \"No credentials found for 'snapcraft' on 'dashboard.snapcraft.io'.\" >&2; exit 1");
      expect(a.login, StoreLogin.loggedOut);
      expect(a.detail, contains('No credentials found'));
    });

    test('reports unavailable when snapcraft is missing', () async {
      final a = await SnapdRepository(SnapCommandTransport(), snapcraftCommand: '${dir.path}/missing').storeAccount();
      expect(a.login, StoreLogin.unavailable);
    });
  });

  testWidgets('sign dialog guides key creation when there are no keys', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero, noKeys: true)),
        initialRoute: const SchemaEditorRoute(networkId),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Add wifi.signal'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign & acknowledge').last);
    await tester.pumpAndSettle();
    expect(find.text('No signing keys found'), findsOneWidget);
    expect(find.text('snap create-key acme-release'), findsOneWidget);
    expect(find.text('snapcraft register-key acme-release'), findsOneWidget);
    await tester.tap(find.text('Refresh keys'));
    await tester.pumpAndSettle();
    expect(find.text('No signing keys found'), findsOneWidget);
  });
}
