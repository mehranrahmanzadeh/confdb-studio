import 'dart:convert';
import 'dart:io';

import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/store/snap_store_client.dart';
import 'package:confdb_studio/data/store/store_auth_client.dart';
import 'package:confdb_studio/domain/store_sync.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Awaits a fake-repository call inside a widget test, whose delays only
/// pass while the test pumps.
Future<T> settle<T>(WidgetTester tester, Future<T> future) async {
  late T result;
  var done = false;
  future.then((v) {
    result = v;
    done = true;
  });
  while (!done) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return result;
}

/// A test double for [StoreAuthClient], recording every call and letting
/// each test script [login]/[restoreCredentials]/[request]'s behavior.
class FakeStoreAuthClient implements StoreAuthClient {
  FakeStoreAuthClient({this.onLogin, this.onRestore, this.onRequest});

  final Future<StoreAuthSession> Function({required StoreEnv env, required String email, required String password, String? otp})?
  onLogin;
  final Future<StoreAuthSession> Function({required StoreEnv env, required String credentialsJson})? onRestore;
  final Future<StoreApiResponse> Function(String method, String path, {String? body, String? contentType})? onRequest;

  final calls = <Map<String, Object?>>[];
  bool loggedOutCalled = false;

  @override
  Future<StoreAuthSession> login({required StoreEnv env, required String email, required String password, String? otp}) {
    calls.add({'op': 'login', 'env': env, 'email': email, 'password': password, 'otp': otp});
    final f = onLogin;
    if (f == null) throw UnimplementedError('no onLogin configured');
    return f(env: env, email: email, password: password, otp: otp);
  }

  @override
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson}) {
    calls.add({'op': 'restoreCredentials', 'env': env, 'credentialsJson': credentialsJson});
    final f = onRestore;
    if (f == null) throw UnimplementedError('no onRestore configured');
    return f(env: env, credentialsJson: credentialsJson);
  }

  @override
  Future<void> logout() async => loggedOutCalled = true;

  @override
  Future<StoreAccountInfo> whoami() async => throw UnimplementedError('whoami is unused by SnapStoreClient');

  @override
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType}) {
    calls.add({'op': 'request', 'method': method, 'path': path, 'body': body, 'contentType': contentType});
    final f = onRequest;
    if (f == null) throw UnimplementedError('no onRequest configured');
    return f(method, path, body: body, contentType: contentType);
  }
}

void main() {
  group('SnapStoreClient', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('store'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// A client over [auth], optionally starting with a saved login (as if
    /// an earlier run had called `login()`).
    SnapStoreClient client({FakeStoreAuthClient? auth, String? savedEnv, String savedCredentials = 'creds'}) {
      final file = File('${dir.path}/store.json');
      if (savedEnv != null) {
        file.writeAsStringSync(jsonEncode({'env': savedEnv, 'credentials_json': savedCredentials}));
      }
      return SnapStoreClient(authClient: auth ?? FakeStoreAuthClient(), authFile: file.path);
    }

    StoreAccountInfo account({String id = 'AbC', String email = 'dev@example.com', String username = 'dev'}) =>
        StoreAccountInfo(id: id, email: email, username: username, displayName: '', permissions: const [], channels: const [], expires: '');

    test('lists schemas, with the revision when the Store sends one', () async {
      final views = {
        'wifi-setup': {
          'rules': [
            {'request': 'ssid', 'storage': 'wifi.ssid'},
          ],
        },
      };
      final networkBody = jsonEncode({
        'storage': {
          'schema': {'wifi': 'any'},
        },
      });
      final auth = FakeStoreAuthClient(
        onRequest: (method, path, {body, contentType}) async => StoreApiResponse(
          status: 200,
          body: jsonEncode({
            'assertions': [
              {
                'headers': {'type': 'confdb-schema', 'account-id': 'AbC', 'authority-id': 'AbC', 'name': 'network', 'views': views},
                'body': networkBody,
              },
              {
                'headers': {'type': 'confdb-schema', 'account-id': 'AbC', 'name': 'fleet', 'revision': '3', 'views': views},
                'body': '',
              },
            ],
          }),
        ),
      );
      final list = await client(auth: auth).listSchemas();
      expect(auth.calls.single, {'op': 'request', 'method': 'GET', 'path': '/api/v2/confdb-schemas', 'body': null, 'contentType': null});
      expect(list.map((s) => s.id.path), ['AbC/network', 'AbC/fleet']);
      expect(list.first.revision, isNull, reason: 'the documented headers leave revision out');
      expect(list.first.view('wifi-setup')?.rules.single.storage, 'wifi.ssid');
      expect(list.last.revision, 3);
    });

    test('sends a signed assertion as x.ubuntu.assertion', () async {
      final auth = FakeStoreAuthClient(
        onRequest: (method, path, {body, contentType}) async =>
            StoreApiResponse(status: 201, body: jsonEncode({'assertions': <Object>[]})),
      );
      await client(auth: auth).register('type: confdb-schema\n\nsig');
      expect(auth.calls.single, {
        'op': 'request',
        'method': 'POST',
        'path': '/api/v2/confdb-schemas',
        'body': 'type: confdb-schema\n\nsig',
        'contentType': 'application/x.ubuntu.assertion',
      });
    });

    test('reports the Store’s error list', () async {
      final auth = FakeStoreAuthClient(
        onRequest: (method, path, {body, contentType}) async => StoreApiResponse(
          status: 400,
          body: jsonEncode({
            'error-list': [
              {'code': 'invalid-request', 'message': 'account-id and authority-id must match the requesting user.'},
            ],
          }),
        ),
      );
      await expectLater(
        client(auth: auth).register('x'),
        throwsA(isA<ConfdbException>().having((e) => e.message, 'message', contains('must match the requesting user'))),
      );
    });

    test('a 401 means the login needs renewing', () async {
      final auth = FakeStoreAuthClient(
        onRequest: (method, path, {body, contentType}) async =>
            throw const ConfdbException('expired', kind: ConfdbErrorKind.signedOut),
        onRestore: ({required env, required credentialsJson}) async =>
            throw const ConfdbException('expired', kind: ConfdbErrorKind.signedOut),
      );
      final c = client(auth: auth, savedEnv: 'production');
      await expectLater(c.listSchemas(), throwsA(isA<ConfdbException>().having((e) => e.kind, 'kind', ConfdbErrorKind.signedOut)));
      expect(await c.session(), isA<StoreSession>().having((s) => s.signedIn, 'signedIn', isFalse));
    });

    test('whoami gives the session', () async {
      final auth = FakeStoreAuthClient(
        onRestore: ({required env, required credentialsJson}) async =>
            StoreAuthSession(account: account(), credentialsJson: credentialsJson),
      );
      final s = await client(auth: auth, savedEnv: 'staging').session();
      expect(s.signedIn, isTrue);
      expect(s.env, StoreEnv.staging);
      expect(s.username, 'dev');
      expect(s.accountId, 'AbC');
    });

    test('no saved login is signed out, not an error', () async {
      final s = await client().session();
      expect(s.signedIn, isFalse);
    });

    test('login reports when a one-time code is needed', () async {
      final auth = FakeStoreAuthClient(
        onLogin: ({required env, required email, required password, otp}) async =>
            throw const ConfdbException('2-factor authentication required.', kind: ConfdbErrorKind.twoFactorRequired),
      );
      final c = client(auth: auth);
      await expectLater(
        c.login(email: 'dev@example.com', password: 'hunter2', env: StoreEnv.staging),
        throwsA(isA<ConfdbException>().having((e) => e.kind, 'kind', ConfdbErrorKind.twoFactorRequired)),
      );
      expect(auth.calls.single, {'op': 'login', 'env': StoreEnv.staging, 'email': 'dev@example.com', 'password': 'hunter2', 'otp': null});
    });

    test('a successful login saves the credentials for next time', () async {
      final auth = FakeStoreAuthClient(
        onLogin: ({required env, required email, required password, otp}) async =>
            StoreAuthSession(account: account(), credentialsJson: 'opaque-blob'),
      );
      final c = client(auth: auth);
      final s = await c.login(email: 'dev@example.com', password: 'hunter2', env: StoreEnv.production);
      expect(s.signedIn, isTrue);
      expect(jsonDecode(File('${dir.path}/store.json').readAsStringSync()), {'env': 'production', 'credentials_json': 'opaque-blob'});
    });
  });

  group('compareWithStore', () {
    ConfdbSchema rev(ConfdbSchema s, int? r) => ConfdbSchema(id: s.id, revision: r, summary: s.summary, views: s.views, storage: s.storage);

    test('by revision when the Store gives one', () {
      expect(compareWithStore(networkRev4, networkRev4), StoreSync.inSync);
      expect(compareWithStore(networkRev4, rev(networkRev4, 5)), StoreSync.storeNewer);
      expect(compareWithStore(networkRev4, rev(networkRev4, 3)), StoreSync.deviceNewer);
    });
    test('by content when it doesn’t', () {
      expect(compareWithStore(networkRev4, rev(networkRev4, null)), StoreSync.inSync);
      expect(compareWithStore(networkRev4, rev(networkDraft, null)), StoreSync.differs);
    });
    test('one side missing', () {
      expect(compareWithStore(telemetryRev1, null), StoreSync.notInStore);
      expect(compareWithStore(null, fleetRev2), StoreSync.storeOnly);
      expect(compareWithStore(systemSnaps, null), StoreSync.unknown);
    });
  });

  group('schemas list', () {
    Future<FakeConfdbRepository> boot(WidgetTester tester, {FakeScenario scenario = const FakeScenario(latency: Duration.zero)}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = FakeConfdbRepository(scenario: scenario);
      await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const OverviewRoute()));
      await tester.pumpAndSettle();
      return repo;
    }

    Future<void> action(WidgetTester tester, String schema, String label) async {
      await tester.tap(find.byTooltip('Actions for acme/$schema'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('shows each schema’s Store state, and schemas only in the Store', (tester) async {
      await boot(tester);
      expect(find.text('Snap Store'), findsOneWidget);
      expect(find.text('In Store · rev 4'), findsOneWidget, reason: 'network');
      expect(find.text('Not in Store'), findsOneWidget, reason: 'telemetry');
      expect(find.text('Only in Store'), findsOneWidget, reason: 'fleet');
      expect(find.text('fleet'), findsOneWidget);
    });

    testWidgets('installs a schema from the Store', (tester) async {
      final repo = await boot(tester);
      await action(tester, 'fleet', 'Install rev 2 from Store');
      expect(find.textContaining('snapd fetches revision 2'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pumpAndSettle();
      expect((await settle(tester, repo.listSchemas())).any((s) => s.id == fleetId && s.revision == 2), isTrue);
      expect(find.text('Only in Store'), findsNothing);
      expect(find.text('In Store · rev 2'), findsOneWidget);
    });

    testWidgets('pushes a schema signed only on this device', (tester) async {
      final repo = await boot(tester);
      await action(tester, 'telemetry', 'Push rev 1 to Store');
      expect(find.textContaining('can’t be removed'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Push to Store'));
      await tester.pumpAndSettle();
      expect((await settle(tester, repo.listStoreSchemas())).any((s) => s.id == telemetryId), isTrue);
      expect(find.text('Not in Store'), findsNothing);
      expect(find.text('In Store · rev 1'), findsOneWidget);
    });

    testWidgets('clicking “Not in Store” offers to push', (tester) async {
      final repo = await boot(tester);
      final badge = find.ancestor(of: find.text('Not in Store'), matching: find.byType(InkWell));
      expect(tester.widget<InkWell>(badge).mouseCursor, WidgetStateMouseCursor.clickable);
      await tester.tap(find.text('Not in Store'));
      await tester.pumpAndSettle();
      expect(find.textContaining('can’t be removed'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Push to Store'));
      await tester.pumpAndSettle();
      expect((await settle(tester, repo.listStoreSchemas())).any((s) => s.id == telemetryId), isTrue);
      expect(find.text('In Store · rev 1'), findsOneWidget);
    });

    testWidgets('opens a Store revision as a draft', (tester) async {
      final repo = await boot(tester);
      await action(tester, 'fleet', 'Open Store revision as draft');
      expect((await settle(tester, repo.listDrafts())).any((d) => d.id == fleetId && d.view('enrol') != null), isTrue);
      expect(find.text('Storage'), findsWidgets, reason: 'the editor opened');
    });

    testWidgets('signed out: explains, then signs in with a one-time code', (tester) async {
      await boot(tester, scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true));
      expect(find.text('Not signed in to the Snap Store'), findsOneWidget);
      expect(find.text('Only in Store'), findsNothing);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Sign in'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'dev@acme.example');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Two-factor authentication'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Authentication code'), '123456');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Not signed in to the Snap Store'), findsNothing);
      expect(find.text('Only in Store'), findsOneWidget);
    });

    testWidgets('a wrong password is reported in the dialog', (tester) async {
      await boot(tester, scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sign in'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'dev@acme.example');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t sign in'), findsOneWidget);
      expect(find.textContaining('not correct'), findsOneWidget);
    });

    testWidgets('a Store that can’t be reached leaves the device’s schemas', (tester) async {
      await boot(tester, scenario: const FakeScenario(latency: Duration.zero, storeOffline: true));
      expect(find.text('network'), findsOneWidget);
      expect(find.text('Only in Store'), findsNothing);
    });
  });

  testWidgets('signing can push the new revision to the Store', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    await tester.pumpWidget(ConfdbStudioApp(repository: repo, initialRoute: const SchemaEditorRoute(networkId)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Add wifi.signal'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign & acknowledge'));
    await tester.pumpAndSettle();

    final push = find.widgetWithText(CheckboxListTile, 'Push to the Snap Store');
    expect(tester.widget<CheckboxListTile>(push).value, isTrue, reason: 'on when signed in');
    expect(find.textContaining('Registers revision 5'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign and acknowledge'));
    await tester.pumpAndSettle();

    expect((await settle(tester, repo.listStoreSchemas())).firstWhere((s) => s.id == networkId).revision, 5);
    expect((await settle(tester, repo.listSchemas())).firstWhere((s) => s.id == networkId).revision, 5);
  });
}
