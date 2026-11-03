// The full [ConfdbRepository] contract against a real snapd: reading and
// writing values through a view, custodian rejection and rollback, write-only
// values, and connecting/disconnecting a custodian snap.
//
// This uses a public confdb-schema signed by a Store-registered key. Stock
// snapd validates the committed assertion chain; no private key is needed.
// Provision the machine with:
//
//   sudo scripts/integration/provision.sh --kind lxd-vm --custodian
//   sudo flutter test test/integration \
//     --dart-define=SNAPD_IT=true --dart-define=SNAPD_IT_CUSTODIAN=true
//
// Tests run serially and reset the fixture's values between them, because they
// share one confdb on one machine.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/environment.dart';
import 'support/fixtures.dart';

void main() async {
  var skip = await integrationSkipReason();
  skip ??= custodianEnabled
      ? null
      : 'Needs the signed fixture schema. Provision with --custodian and run with --dart-define=SNAPD_IT_CUSTODIAN=true.';

  for (final tc in transportCases) {
    group(tc.name, skip: skip, () {
      late final transport = tc.create();
      late Directory drafts;
      late SnapdRepository repo;

      setUpAll(() async {
        // Re-checked here, not just at load time: nothing in this group may
        // run on a machine that isn't disposable.
        await requireDisposableEnvironment();
      });

      setUp(() async {
        drafts = Directory.systemTemp.createTempSync('confdb-it-drafts');
        repo = repositoryFor(transport, drafts);
        await _resetFixture(repo);
      });

      tearDown(() async {
        await _resetFixture(repo);
        drafts.deleteSync(recursive: true);
      });

      tearDownAll(() => transport.close());

      test('the fixture schema is acknowledged and has the expected rules', () async {
        final schemas = await repo.listSchemas();
        final schema = schemas.where((s) => s.id == fixtureSchema).firstOrNull;
        expect(
          schema,
          isNotNull,
          reason: 'provision.sh --custodian should have acked ${fixtureSchema.path}; found ${schemas.map((s) => s.id.path).toList()}',
        );
        expect(schema!.builtIn, isFalse);
        expect(schema.signedBy, isNotNull);

        final view = schema.view(fixtureView.view);
        expect(view, isNotNull);
        final byRequest = {for (final r in view!.rules) r.request: r};
        expect(byRequest.keys, containsAll(['ssid', 'password', 'status']));
        // The access modes the rest of this suite relies on.
        expect(byRequest['ssid']!.access.canRead && byRequest['ssid']!.access.canWrite, isTrue);
        expect(byRequest['password']!.access.canWrite, isTrue);
        expect(byRequest['password']!.access.canRead, isFalse);
        expect(byRequest['status']!.access.canWrite, isFalse);
      });

      test('the custodian snap is listed and connected', () async {
        final snaps = await repo.listSnaps();
        final custodian = snaps.where((s) => s.name == fixtureCustodian).firstOrNull;
        expect(custodian, isNotNull, reason: 'found ${snaps.map((s) => s.name).toList()}');

        final plug = custodian!.plugs.firstWhere((p) => p.view == fixtureView);
        expect(plug.role, PlugRole.custodian);
        expect(plug.state, ConnState.connected);
      });

      test('a write is applied and read back', () async {
        final change = await repo.applyValues(fixtureView, {'ssid': 'integration-net'});
        expect(change.status, ChangeStatus.done, reason: change.error ?? '');

        // The change should describe what it did, for the pending-change tray.
        final diff = change.values.firstWhere((v) => v.key == 'ssid');
        expect(diff.after, contains('integration-net'));

        final snapshot = await repo.readView(fixtureView);
        expect(snapshot.loadFailure, isNull);
        final ssid = snapshot.entries.firstWhere((e) => e.key == 'ssid');
        expect(ssid.hasValue, isTrue);
        expect(ssid.value, 'integration-net');
      });

      test('a null value unsets the path', () async {
        await repo.applyValues(fixtureView, {'ssid': 'to-be-removed'});
        expect((await _entry(repo, 'ssid')).hasValue, isTrue);

        final change = await repo.applyValues(fixtureView, {'ssid': null});
        expect(change.status, ChangeStatus.done, reason: change.error ?? '');

        expect((await _entry(repo, 'ssid')).hasValue, isFalse);
      });

      test('several values are written as one change', () async {
        final change = await repo.applyValues(fixtureView, {'ssid': 'multi-net', 'private.team': 'green'});
        expect(change.status, ChangeStatus.done, reason: change.error ?? '');
        expect(change.values.map((v) => v.key), containsAll(['ssid', 'private.team']));

        final snapshot = await repo.readView(fixtureView);
        expect(snapshot.entries.firstWhere((e) => e.key == 'ssid').value, 'multi-net');
        // A placeholder rule is reported as one entry holding the whole
        // collection, not one entry per concrete path.
        expect(_placeholder(snapshot), containsPair('team', 'green'));
      });

      test('non-string types survive the round trip', () async {
        final change = await repo.applyValues(fixtureView, {'private.count': 3, 'private.on': true});
        expect(change.status, ChangeStatus.done, reason: change.error ?? '');

        final values = _placeholder(await repo.readView(fixtureView));
        // snapd stores JSON, so these must not come back stringified.
        expect(values['count'], 3);
        expect(values['on'], true);
      });

      test('a custodian rejection comes back as an error change, not an exception', () async {
        // The fixture custodian's change-view hook refuses this SSID.
        final change = await repo.applyValues(fixtureView, {'ssid': 'reject-me'});

        // Contract: a rejected change is a *completed change with an error
        // status*, so the UI can show which step failed. It must not throw.
        expect(change.status, ChangeStatus.error);
        expect(change.error, isNotNull);
        expect(change.error, contains('custodian'));

        // And it must have been rolled back.
        expect((await _entry(repo, 'ssid')).hasValue, isFalse, reason: 'the rejected write was not rolled back');
      });

      test('a rejection leaves an earlier value untouched', () async {
        await repo.applyValues(fixtureView, {'ssid': 'keep-me'});

        final change = await repo.applyValues(fixtureView, {'ssid': 'reject-me'});
        expect(change.status, ChangeStatus.error);

        expect((await _entry(repo, 'ssid')).value, 'keep-me');
      });

      test('a write-only value is never exposed', () async {
        final change = await repo.applyValues(fixtureView, {'password': 'hunter2'});
        expect(change.status, ChangeStatus.done, reason: change.error ?? '');

        // The change's own record must not carry the secret into the tray.
        final diff = change.values.firstWhere((v) => v.key == 'password');
        expect(diff.after, isNot(contains('hunter2')));

        final snapshot = await repo.readView(fixtureView);
        final password = snapshot.entries.firstWhere((e) => e.key == 'password');
        expect(password.value, isNull, reason: 'a write-only value must not be readable');
        // Nothing anywhere in the snapshot may leak it.
        expect(snapshot.entries.map((e) => '${e.value}').join(' '), isNot(contains('hunter2')));
      });

      test('writing a read-only path fails with a ConfdbException', () async {
        await expectLater(
          repo.applyValues(fixtureView, {'status': 'up'}),
          throwsA(isA<ConfdbException>().having((e) => e.message, 'message', isNotEmpty)),
        );
      });

      test('writing an unknown path fails with a ConfdbException', () async {
        await expectLater(repo.applyValues(fixtureView, {'definitely-not-a-rule': 'x'}), throwsA(isA<ConfdbException>()));
      });

      test('a write notifies listeners', () async {
        final seen = <void>[];
        final sub = repo.onChanged.listen(seen.add);
        addTearDown(sub.cancel);

        await repo.applyValues(fixtureView, {'ssid': 'notify-net'});
        // The stream is broadcast and synchronous-ish; give it a turn.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(seen, isNotEmpty);
      });

      test('disconnecting the custodian makes the view unreadable, and reconnecting restores it', () async {
        final snaps = await repo.listSnaps();
        final plug = snaps.firstWhere((s) => s.name == fixtureCustodian).plugs.firstWhere((p) => p.view == fixtureView);

        final off = await repo.disconnect(plug);
        expect(off.status, ChangeStatus.done, reason: off.error ?? '');
        // Put it back even if the assertions below fail.
        addTearDown(() async {
          final again = await repo.listSnaps();
          final p = again.firstWhere((s) => s.name == fixtureCustodian).plugs.firstWhere((x) => x.view == fixtureView);
          if (p.state != ConnState.connected) await repo.connect(p);
        });

        // snapd refuses value access to a view with no custodian connected.
        await expectLater(repo.readView(fixtureView), throwsA(isA<ConfdbException>()));

        final back = await repo.listSnaps();
        final disconnected = back.firstWhere((s) => s.name == fixtureCustodian).plugs.firstWhere((p) => p.view == fixtureView);
        expect(disconnected.state, isNot(ConnState.connected));

        final on = await repo.connect(disconnected);
        expect(on.status, ChangeStatus.done, reason: on.error ?? '');
        final snapshot = await repo.readView(fixtureView);
        expect(snapshot.ref, fixtureView);
      });
    });
  }
}

/// The entry for [key] in the fixture view.
Future<ViewEntry> _entry(SnapdRepository repo, String key) async {
  final snapshot = await repo.readView(fixtureView);
  return snapshot.entries.firstWhere((e) => e.key == key);
}

/// The collection behind the view's `private.{placeholder}` rule.
Map _placeholder(ViewSnapshot snapshot) {
  final entry = snapshot.entries.firstWhere((e) => e.rule.request.contains('{placeholder}'));
  return (entry.value as Map?) ?? const {};
}

/// Clears everything the suite writes, so each test starts from the same place.
///
/// Unsets concrete paths rather than whatever [ViewSnapshot] reports: a
/// placeholder rule like `private.{placeholder}` is reported as one entry
/// holding the whole collection, and its request isn't a path you can write to.
/// Unsetting a path that holds nothing is not an error for snapd.
Future<void> _resetFixture(SnapdRepository repo) async {
  try {
    await repo.applyValues(fixtureView, {for (final k in fixtureWritablePaths) k: null});
  } on ConfdbException catch (e) {
    // Don't let leftover state hide the real failure of whichever test is
    // about to run, but do say so.
    // ignore: avoid_print
    print('warning: couldn’t reset the fixture: $e');
  }
}
