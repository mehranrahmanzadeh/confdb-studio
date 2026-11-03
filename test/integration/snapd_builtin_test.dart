// Repository behaviour against a real snapd, using only what stock snapd
// already has — no signed fixtures, no store credentials.
//
// snapd compiles in one confdb-schema, `system/validation-sets`, so a plain
// Ubuntu runner can exercise the schema-reading half of [ConfdbRepository]
// against a genuine snapd assertion rather than a hand-written sample. The
// value-reading half needs a custodian snap, which needs a signed schema,
// which needs a test-keys snapd — that's snapd_custodian_test.dart.
//
//   sudo scripts/integration/provision.sh --kind lxd-vm
//   sudo flutter test test/integration --dart-define=SNAPD_IT=true
import 'dart:io';

import 'package:confdb_studio/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/environment.dart';
import 'support/fixtures.dart';

void main() async {
  final skip = await integrationSkipReason();

  for (final tc in transportCases) {
    group(tc.name, skip: skip, () {
      late Directory drafts;
      late final transport = tc.create();

      setUpAll(() async {
        final env = await requireDisposableEnvironment();
        // ignore: avoid_print
        print('${tc.name}: running in $env');
      });
      setUp(() => drafts = Directory.systemTemp.createTempSync('confdb-it-drafts'));
      tearDown(() => drafts.deleteSync(recursive: true));
      tearDownAll(() => transport.close());

      test('reports a snapd version and that confdb is enabled', () async {
        final repo = repositoryFor(transport, drafts);
        final status = await repo.systemStatus();
        expect(status.snapdVersion, isNotEmpty);
        // provision.sh turns the feature on; if it's off, the rest of the
        // suite would fail in a much less obvious way.
        expect(status.confdbEnabled, isTrue, reason: 'experimental.confdb is off. Run scripts/integration/provision.sh.');
      });

      test('parses snapd’s built-in schema assertion', () async {
        final repo = repositoryFor(transport, drafts);
        final schemas = await repo.listSchemas();
        final built = schemas.where((s) => s.id == builtInSchema).firstOrNull;
        expect(built, isNotNull, reason: 'snapd should always know ${builtInSchema.path}; found ${schemas.map((s) => s.id.path).toList()}');

        // A schema under the `system` account is snapd's own and can't be
        // edited or re-signed, which is what `builtIn` means to the UI.
        expect(built!.builtIn, isTrue);
        expect(built.revision, isNull);
        expect(built.views, isNotEmpty);

        // The codec should have produced usable rules, not just a name.
        final view = built.view('state');
        expect(view, isNotNull, reason: 'views: ${built.views.map((v) => v.name).toList()}');
        expect(view!.rules, isNotEmpty);
        expect(view.rules.every((r) => r.request.isNotEmpty && r.storage.isNotEmpty), isTrue);
        // `state` is snapd's read-only view of what's installed.
        expect(view.rules.every((r) => r.access.canRead), isTrue);
        expect(view.rules.any((r) => r.access.canWrite), isFalse);
      });

      test('every acknowledged schema round-trips through the codec', () async {
        final repo = repositoryFor(transport, drafts);
        for (final s in await repo.listSchemas()) {
          expect(s.id.account, isNotEmpty);
          expect(s.id.name, isNotEmpty);
          for (final v in s.views) {
            expect(v.name, isNotEmpty, reason: 'unnamed view in ${s.id.path}');
            // A view with no rules would silently render an empty screen.
            expect(v.rules, isNotEmpty, reason: '${s.id.path}/${v.name} parsed with no rules');
          }
        }
      });

      test('lists snaps that have confdb plugs', () async {
        final repo = repositoryFor(transport, drafts);
        // May legitimately be empty on a bare runner; what matters is that the
        // connections/interfaces parsing doesn't throw and stays self-consistent.
        for (final snap in await repo.listSnaps()) {
          expect(snap.name, isNotEmpty);
          expect(snap.plugs, isNotEmpty, reason: '${snap.name} was listed without a confdb plug');
          for (final p in snap.plugs) {
            expect(p.snap, snap.name);
            expect(p.view.path.split('/'), hasLength(3));
          }
        }
      });

      test('reading a view with no custodian fails as a ConfdbException', () async {
        final repo = repositoryFor(transport, drafts);
        // snapd refuses value access to a view that has no custodian snap
        // connected. Nothing can be connected to a `system` schema, so this is
        // a deterministic error path on any stock snapd — and it must surface
        // as a ConfdbException, not as a success-shaped empty snapshot.
        await expectLater(
          repo.readView(builtInSchema.view('state')),
          throwsA(
            isA<ConfdbException>()
                .having((e) => e.message, 'message', isNotEmpty)
                .having((e) => e.kind, 'kind', anyOf(ConfdbErrorKind.other, ConfdbErrorKind.permissionDenied, ConfdbErrorKind.notFound)),
          ),
        );
      });

      test('an unknown schema is reported as notFound, not as an empty view', () async {
        final repo = repositoryFor(transport, drafts);
        await expectLater(
          repo.readView(const ViewRef('nosuchaccount', 'nosuchschema', 'nosuchview')),
          throwsA(isA<ConfdbException>().having((e) => e.kind, 'kind', ConfdbErrorKind.notFound)),
        );
      });

      test('signing keys come back from the host keyring', () async {
        final repo = repositoryFor(transport, drafts);
        // A fresh machine has no keys; the point is that `snap keys` is parsed
        // rather than throwing on its empty output.
        for (final k in await repo.signingKeys()) {
          expect(k.name, isNotEmpty);
          expect(k.sha3384, isNotEmpty);
        }
      });

      test('drafts are stored and discarded on disk', () async {
        final repo = repositoryFor(transport, drafts);
        expect(await repo.listDrafts(), isEmpty);

        final built = (await repo.listSchemas()).firstWhere((s) => s.id == builtInSchema);
        // Reuse the built-in schema's shape under an account of our own: it's a
        // real snapd-shaped schema, so this exercises the codec in both
        // directions rather than a hand-written sample.
        final draft = ConfdbSchema(
          id: const SchemaId('integration', 'draft'),
          views: built.views,
          storage: built.storage,
          aliases: built.aliases,
          summary: built.summary,
          isDraft: true,
        );
        await repo.saveDraft(draft);

        final saved = await repo.listDrafts();
        expect(saved.map((d) => d.id.path), ['integration/draft']);
        expect(saved.single.views.map((v) => v.name), built.views.map((v) => v.name));

        await repo.discardDraft(draft.id);
        expect(await repo.listDrafts(), isEmpty);
      });
    });
  }
}
