import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:confdb_studio/data/drafts/file_draft_store.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:confdb_studio/data/snapd/transport.dart';
import 'package:confdb_studio/data/store/snap_store_client.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'store_fixture.dart';

const _enabled = bool.fromEnvironment('SNAPD_IT');
const _id = SchemaId('developer1', 'studio');
final _admin = _id.view('admin');
const _snapName = 'studio-custodian';

Matcher _error(ConfdbErrorKind kind) => isA<ConfdbException>().having((e) => e.kind, 'kind', kind);

void main() {
  for (final shell in [false, true]) {
    group(shell ? 'real snapd / snap command' : 'real snapd / Unix socket', skip: !_enabled, () {
      late Directory temp;
      late SnapdTransport transport;
      late SnapdRepository repo;
      late IntegrationStore store;
      late SigningKey key;
      late String fixtureRoot;
      late StreamSubscription<void> subscription;
      var notifications = 0;

      Future<ConfdbSchema> schema() async => (await repo.listSchemas()).singleWhere((s) => s.id == _id);
      Future<ConfdbPlug> plug(String name) async =>
          (await repo.listSnaps()).singleWhere((s) => s.name == _snapName).plugs.singleWhere((p) => p.plug == name);
      Future<ViewEntry> entry(String name) async => (await repo.readView(_admin)).entries.singleWhere((e) => e.key == name);
      Future<void> notified(Future<void> Function() action) async {
        final event = repo.onChanged.first.timeout(const Duration(seconds: 5));
        await action();
        await event;
      }

      setUpAll(() {
        if (!File('/run/confdb-integration-vm').existsSync() || Platform.environment['CONFDB_IT_ROOT'] == null) {
          throw StateError('Destructive suite: run scripts/test_snapd_integration.sh, not against host snapd.');
        }
        fixtureRoot = Platform.environment['CONFDB_IT_ROOT']!;
      });

      setUp(() async {
        temp = await Directory.systemTemp.createTemp('confdb-it-');
        transport = shell ? SnapCommandTransport(pkexec: 'env') : UnixSocketTransport();
        final keys = await Process.run('snap', ['keys', '--json']);
        expect(keys.exitCode, 0, reason: '${keys.stderr}');
        final rawKey = (jsonDecode(keys.stdout as String) as List).cast<Map>().singleWhere((k) => k['name'] == 'integration');
        key = SigningKey(name: 'integration', sha3384: rawKey['sha3-384'] as String);
        store = IntegrationStore(Directory('$fixtureRoot/remote'), key.sha3384);
        repo = SnapdRepository(
          transport,
          elevated: transport,
          drafts: FileDraftStore(dir: Directory('${temp.path}/drafts')),
          snapCommand: '${Directory.current.path}/scripts/integration/snap',
          store: SnapStoreClient(authClient: store, authFile: '${temp.path}/store.json'),
        );
        notifications = 0;
        subscription = repo.onChanged.listen((_) => notifications++);
        final failLoad = File('/var/snap/$_snapName/common/fail-load');
        if (await failLoad.exists()) await failLoad.delete();
        if (!(await repo.systemStatus()).confdbEnabled) await repo.enableConfdb();
        for (final name in ['admin', 'observer', 'reader']) {
          final p = await plug(name);
          if (!p.state.isConnected) expect((await repo.connect(p)).status, ChangeStatus.done);
        }
        final reset = await repo.applyValues(_admin, {
          'name': 'baseline',
          'count': 1,
          'enabled': true,
          'items': ['one'],
          'labels': {'site': 'lab'},
          'password': 'test-password',
          'token': 'test-token',
        });
        expect(reset.status, ChangeStatus.done, reason: reset.error);
      });

      tearDown(() async {
        await subscription.cancel();
        transport.close();
        await temp.delete(recursive: true);
      });

      test('backend name and system status; enabling confdb emits an event', () async {
        expect(repo.backendName, shell ? 'snap command' : 'snapd REST');
        final status = await repo.systemStatus();
        expect(status.snapdVersion, isNotEmpty);
        expect(status.confdbEnabled, isTrue);
        final disabled = await Process.run('snap', ['set', 'system', 'experimental.confdb=false']);
        expect(disabled.exitCode, 0, reason: '${disabled.stderr}');
        try {
          expect((await repo.systemStatus()).confdbEnabled, isFalse);
          await notified(repo.enableConfdb);
          expect((await repo.systemStatus()).confdbEnabled, isTrue);
        } finally {
          await repo.enableConfdb();
        }
      });

      test('developer account and locally acknowledged account', () async {
        expect(await repo.developerAccount(), 'developer1');
        final account = await repo.account('developer1');
        expect(account, isNotNull);
        expect(account!.id, 'developer1');
        expect(account.username, 'developer1');
        expect(account.displayName, isNotEmpty);
      });

      test('lists and decodes the signed schema, rules and storage', () async {
        final s = await schema();
        expect(s.revision, greaterThanOrEqualTo(1));
        expect(s.isDraft, isFalse);
        expect(s.view('admin')!.rules.map((r) => r.request), containsAll(['name', 'password', 'labels.{key}', 'runtime']));
        expect(s.storage.children.singleWhere((n) => n.key == 'token').secret, isTrue);
        expect(s.storage.children.singleWhere((n) => n.key == 'runtime').ephemeral, isTrue);
      });

      test('draft save, replace, persistence, discard and notifications', () async {
        final draft = (await schema()).copyWith(isDraft: true, baseRevision: (await schema()).revision);
        await notified(() => repo.saveDraft(draft));
        expect((await repo.listDrafts()).single.id, _id);
        await repo.saveDraft(draft.copyWith(summary: 'edited'));
        final reloaded = await FileDraftStore(dir: Directory('${temp.path}/drafts')).list();
        expect(reloaded.single.summary, 'edited');
        expect(reloaded.single.baseRevision, draft.baseRevision);
        await notified(() => repo.discardDraft(_id));
        expect(await repo.listDrafts(), isEmpty);
        await repo.discardDraft(_id);
      });

      test('imports both unsigned JSON and signed assertions as revision-based drafts', () async {
        final current = await schema();
        final json = File('${temp.path}/draft.json');
        await json.writeAsString(jsonEncode(signInput(current, revision: 1, timestamp: DateTime.now())));
        final imported = await repo.importSchema(json.path);
        expect(imported.isDraft, isTrue);
        expect(imported.baseRevision, current.revision);
        expect(imported.storage.children.length, current.storage.children.length);
        final signed = await repo.importSchema('$fixtureRoot/schema.assert');
        expect(signed.id, _id);
        expect(signed.baseRevision, current.revision);
        expect((await repo.listDrafts()).single.id, _id);
        final invalid = File('${temp.path}/invalid.json');
        await invalid.writeAsString('{}');
        await expectLater(repo.importSchema(invalid.path), throwsA(isA<SchemaFormatException>()));
        await expectLater(repo.importSchema('${temp.path}/missing'), throwsA(isA<FileSystemException>()));
      });

      test('reads typed values, placeholders and ephemeral load-hook results', () async {
        final snapshot = await repo.readView(_admin);
        expect(snapshot.loadFailure, isNull);
        expect(snapshot.ref, _admin);
        expect(snapshot.entries.singleWhere((e) => e.key == 'name').value, 'baseline');
        expect(snapshot.entries.singleWhere((e) => e.key == 'count').value, 1);
        expect(snapshot.entries.singleWhere((e) => e.key == 'enabled').value, isTrue);
        expect(snapshot.entries.singleWhere((e) => e.key == 'items').value, ['one']);
        expect(snapshot.entries.singleWhere((e) => e.key == 'runtime').value, 'loaded');
        expect(snapshot.entries.singleWhere((e) => e.key == 'labels.{key}').value, {'site': 'lab'});
        final password = snapshot.entries.singleWhere((e) => e.key == 'password');
        expect(password.writeOnly, isTrue);
        expect(password.value, isNull);
        expect(password.masked, isTrue);
        expect(snapshot.entries.singleWhere((e) => e.key == 'token').masked, isTrue);
      });

      test('one multi-value change commits, reports diffs and notifies observers', () async {
        final count = notifications;
        final change = await repo.applyValues(_admin, {
          'name': 'updated',
          'count': 42,
          'enabled': false,
          'items': ['a', 'b'],
          'labels.site': 'new-site',
        });
        expect(change.status, ChangeStatus.done, reason: change.error);
        expect(change.id, greaterThan(0));
        expect(change.readyTime, isNotNull);
        expect(change.view, _admin);
        expect(change.values, hasLength(5));
        expect(change.values.singleWhere((v) => v.key == 'name').before, contains('baseline'));
        expect(change.values.singleWhere((v) => v.key == 'name').after, contains('updated'));
        expect(change.steps, isNotEmpty);
        expect(change.custodian, _snapName);
        expect(change.observers, contains(_snapName));
        expect(notifications, greaterThan(count));
        expect((await entry('count')).value, 42);
        expect((await entry('enabled')).value, false);
        expect((await entry('items')).value, ['a', 'b']);
        expect((await entry('labels.{key}')).value, {'site': 'new-site'});
        expect(await File('/var/snap/$_snapName/common/observed-name').readAsString(), 'updated\n');
        final observer = await repo.readView(_id.view('observer'));
        expect(observer.entries.singleWhere((e) => e.key == 'name').value, 'updated');
      });

      test('null unsets a path, leaving other values unchanged', () async {
        final change = await repo.applyValues(_admin, {'count': null, 'labels.site': null});
        expect(change.status, ChangeStatus.done, reason: change.error);
        expect((await entry('count')).hasValue, isFalse);
        expect((await entry('name')).value, 'baseline');
      });

      test('write-only and secret diffs never display their attempted values', () async {
        final change = await repo.applyValues(_admin, {'password': 'private-password', 'token': 'private-token'});
        expect(change.status, ChangeStatus.done, reason: change.error);
        for (final diff in change.values) {
          expect(diff.secret, isTrue);
          expect(diff.before, isNot(contains('test-')));
          expect(diff.after, isNot(contains('private-')));
        }
        expect(change.detail, isNot(contains('private-')));
        expect((await entry('password')).value, isNull);
      });

      test('custodian rejection is an error change and rolls back every value', () async {
        final change = await repo.applyValues(_admin, {'name': 'reject', 'count': 99});
        expect(change.status, ChangeStatus.error);
        expect(change.error, contains('integration custodian rejected name'));
        expect(change.rejectedBy, _snapName);
        expect(change.steps.any((s) => s.state == ChangeStepState.failed), isTrue);
        expect((await entry('name')).value, 'baseline');
        expect((await entry('count')).value, 1);
      });

      test('schema validation fails atomically, distinct from a successful change', () async {
        try {
          final change = await repo.applyValues(_admin, {'name': 'must-not-commit', 'count': 'not-an-int'});
          expect(change.status, ChangeStatus.error);
          expect(change.error, isNotEmpty);
        } on ConfdbException catch (e) {
          expect(e.message, contains('count'));
        }
        expect((await entry('name')).value, 'baseline');
        expect((await entry('count')).value, 1);
        await expectLater(repo.applyValues(_admin, {'status': 'forbidden'}), throwsA(isA<ConfdbException>()));
        await expectLater(repo.applyValues(_id.view('observer'), {'name': 'forbidden'}), throwsA(isA<ConfdbException>()));
      });

      test('unknown schema/view and unmapped request paths fail explicitly', () async {
        await expectLater(repo.readView(const ViewRef('developer1', 'absent', 'admin')), throwsA(_error(ConfdbErrorKind.notFound)));
        await expectLater(repo.readView(_id.view('absent')), throwsA(_error(ConfdbErrorKind.notFound)));
        await expectLater(repo.applyValues(_admin, {'unmapped': true}), throwsA(isA<ConfdbException>()));
      });

      test('load hook failure is surfaced on the snapshot and ephemeral entry', () async {
        final flag = File('/var/snap/$_snapName/common/fail-load');
        await flag.writeAsString('fail');
        try {
          final snapshot = await repo.readView(_admin);
          expect(snapshot.loadFailure, isNotNull);
          expect(snapshot.loadFailure!.message, contains('integration load failure'));
          expect(snapshot.entries.singleWhere((e) => e.key == 'runtime').loadError, contains('integration load failure'));
        } finally {
          await flag.delete();
        }
        expect((await repo.readView(_admin)).loadFailure, isNull);
      });

      test('snap inventory, hook discovery, disconnect and reconnect', () async {
        final snap = (await repo.listSnaps()).singleWhere((s) => s.name == _snapName);
        expect(snap.publisherSigned, isFalse);
        expect(snap.revision, startsWith('x'));
        expect(snap.hooksKnown, isTrue);
        expect(snap.hooks.map((h) => h.name), containsAll(['change-view-admin', 'load-view-admin', 'observe-view-observer']));
        expect(snap.plugs.singleWhere((p) => p.plug == 'admin').role, PlugRole.custodian);
        expect(snap.plugs.singleWhere((p) => p.plug == 'observer').role, PlugRole.observer);
        final p = await plug('observer');
        final disconnected = await repo.disconnect(p);
        expect(disconnected.status, ChangeStatus.done, reason: disconnected.error);
        expect((await plug('observer')).state, ConnState.notConnected);
        final connected = await repo.connect(await plug('observer'));
        expect(connected.status, ChangeStatus.done, reason: connected.error);
        expect((await plug('observer')).state.isConnected, isTrue);
        expect(connected.steps, isNotEmpty);
      });

      test('no connected custodian produces an explicit failure', () async {
        final p = await plug('admin');
        expect((await repo.disconnect(p)).status, ChangeStatus.done);
        try {
          await expectLater(repo.applyValues(_admin, {'name': 'no-custodian'}), throwsA(isA<ConfdbException>()));
        } finally {
          expect((await repo.connect(p)).status, ChangeStatus.done);
        }
      });

      test('real keyring lists, creates, rejects duplicates, and exports registration requests', () async {
        expect((await repo.signingKeys()).map((k) => k.sha3384), contains(key.sha3384));
        await expectLater(repo.createSigningKey('Invalid key'), throwsA(isA<ConfdbException>()));
        await expectLater(repo.createSigningKey('integration'), throwsA(isA<ConfdbException>()));
        final created = await repo.createSigningKey(shell ? 'created-shell' : 'created-socket');
        addTearDown(() async {
          final removed = await Process.run('snap', ['delete-key', created.name]);
          expect(removed.exitCode, 0, reason: '${removed.stderr}');
        });
        expect(created.sha3384, isNotEmpty);
        expect((await repo.signingKeys()).map((k) => k.sha3384), contains(created.sha3384));
        await repo.registerKey(created);
        expect(store.keyRequests, hasLength(1));
        expect(store.keyRequests.single, startsWith('type: account-key-request\n'));
        expect(store.keyRequests.single, contains('account-id: developer1'));
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('signs and acknowledges a new revision, deletes draft and emits phases', () async {
        final current = await schema();
        final draft = current.copyWith(isDraft: true, summary: 'signed locally');
        await repo.saveDraft(draft);
        final phases = <SignPhase>[];
        await notified(() => repo.signAndAcknowledge(draft, key, onPhase: phases.add));
        final signed = await schema();
        expect(signed.revision, current.revision! + 1);
        expect(signed.summary, 'signed locally');
        expect(await repo.listDrafts(), isEmpty);
        expect(phases, [SignPhase.signing, SignPhase.acknowledging]);
        expect(store.registered, isEmpty);
        expect((await entry('name')).value, 'baseline');
      });

      test('push-before-ack uses Store headers and installs a verifiable signed revision', () async {
        final current = await schema();
        final phases = <SignPhase>[];
        await repo.signAndAcknowledge(current.copyWith(isDraft: true), key, push: true, onPhase: phases.add);
        final signed = await schema();
        expect(signed.revision, greaterThanOrEqualTo(20));
        expect(signed.revision, greaterThan(current.revision!));
        expect(store.registered, hasLength(1));
        expect(phases, [SignPhase.signing, SignPhase.pushing, SignPhase.acknowledging]);
        expect((await repo.listStoreSchemas()).single.revision, signed.revision);
      });

      test('Store rejection leaves acknowledged revision and draft unchanged', () async {
        final current = await schema();
        await repo.saveDraft(current.copyWith(isDraft: true));
        store.rejectRegistration = true;
        final phases = <SignPhase>[];
        await expectLater(
          repo.signAndAcknowledge(current, key, push: true, onPhase: phases.add),
          throwsA(isA<ConfdbException>().having((e) => e.message, 'message', contains('test Store rejected schema'))),
        );
        expect((await schema()).revision, current.revision);
        expect(await repo.listDrafts(), hasLength(1));
        expect(phases, [SignPhase.signing, SignPhase.pushing]);
      });

      test('signing and missing key-registration failures preserve the acknowledged schema and draft', () async {
        final current = await schema();
        await repo.saveDraft(current.copyWith(isDraft: true));
        await expectLater(
          repo.signAndAcknowledge(current, const SigningKey(name: 'does-not-exist', sha3384: '')),
          throwsA(isA<ConfdbException>().having((e) => e.message, 'message', contains('snap sign'))),
        );
        final accountKey = File('$fixtureRoot/remote/account-key');
        final saved = await accountKey.readAsString();
        await accountKey.delete();
        try {
          await expectLater(
            repo.signAndAcknowledge(current, key),
            throwsA(isA<ConfdbException>().having((e) => e.message, 'message', contains('registered'))),
          );
        } finally {
          await accountKey.writeAsString(saved);
        }
        expect((await schema()).revision, current.revision);
        expect(await repo.listDrafts(), hasLength(1));
      });

      test('pushes the real acknowledged assertion and installs from the test assertion service', () async {
        await notified(() => repo.pushToStore(_id));
        expect(parseSchemaFile(store.registered.single).revision, (await schema()).revision);
        final source = await schema();
        final input = signInput(source, revision: source.revision! + 1, timestamp: DateTime.now());
        final proc = await Process.start('snap', ['sign', '-k', key.name]);
        proc.stdin.write(jsonEncode(input));
        await proc.stdin.close();
        final output = proc.stdout.transform(utf8.decoder).join();
        final error = proc.stderr.transform(utf8.decoder).join();
        expect(await proc.exitCode, 0, reason: await error);
        await File('$fixtureRoot/remote/confdb-schema').writeAsString(await output);
        await notified(() => repo.installFromStore(_id));
        expect((await schema()).revision, source.revision! + 1);
        const missing = SchemaId('developer1', 'not-in-store');
        await expectLater(repo.installFromStore(missing), throwsA(_error(ConfdbErrorKind.notFound)));
        await expectLater(repo.pushToStore(missing), throwsA(_error(ConfdbErrorKind.notFound)));
      });

      test('Store session, 2FA, cancel, login, restored credentials and logout delegation', () async {
        expect((await repo.storeSession()).signedIn, isFalse);
        await expectLater(
          repo.storeLogin(email: IntegrationStore.account.email, password: 'test-only'),
          throwsA(_error(ConfdbErrorKind.twoFactorRequired)),
        );
        await repo.storeCancelLogin();
        expect(store.cancelled, isTrue);
        final session = await repo.storeLogin(
          email: IntegrationStore.account.email,
          password: 'test-only',
          otp: '123456',
          env: StoreEnv.staging,
        );
        expect(session.accountId, 'developer1');
        expect(session.env, StoreEnv.staging);
        expect((await repo.storeSession()).signedIn, isTrue);
        await repo.storeLogout();
        expect(store.loggedOut, isTrue);
        expect((await repo.storeSession()).signedIn, isFalse);
      });

      test('registered Store key digests distinguish unavailable from genuine failures', () async {
        expect(await repo.registeredStoreKeyDigests(), {key.sha3384});
        for (final error in [ConfdbErrorKind.signedOut, ConfdbErrorKind.offline]) {
          store.accountError = error;
          expect(await repo.registeredStoreKeyDigests(), isNull);
        }
        store.accountError = ConfdbErrorKind.other;
        await expectLater(repo.registeredStoreKeyDigests(), throwsA(_error(ConfdbErrorKind.other)));
      });

      test('unprivileged snapd requests report permission denial', () async {
        final unprivileged = SnapCommandTransport(snap: '${Directory.current.path}/scripts/integration/unprivileged-snap', pkexec: 'env');
        final denied = SnapdRepository(unprivileged, elevated: unprivileged, store: repo.store);
        try {
          expect((await denied.systemStatus()).snapdVersion, isNotEmpty);
          await expectLater(denied.readView(_admin), throwsA(_error(ConfdbErrorKind.permissionDenied)));
          await expectLater(denied.applyValues(_admin, {'name': 'forbidden'}), throwsA(_error(ConfdbErrorKind.permissionDenied)));
          expect((await entry('name')).value, 'baseline');
        } finally {
          unprivileged.close();
        }
      });

      test('missing snapd socket or command surfaces unreachable, not an empty success', () async {
        final unavailable = shell
            ? SnapCommandTransport(snap: '${temp.path}/missing-snap')
            : UnixSocketTransport(socketPath: '${temp.path}/missing.socket');
        try {
          await expectLater(unavailable.request('GET', '/v2/system-info'), throwsA(_error(ConfdbErrorKind.unreachable)));
        } finally {
          unavailable.close();
        }
      });
    });
  }
}
