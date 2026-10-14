import 'dart:convert';
import 'dart:io';

import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/access.dart';
import 'package:confdb_studio/domain/analysis.dart';
import 'package:confdb_studio/domain/playground.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:confdb_studio/domain/values.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('schema codec', () {
    test('decodes a real confdb-schema assertion from snapd', () {
      final a = jsonDecode(File('test/fixtures/validation_sets_assertion.json').readAsStringSync()) as Map;
      final s = schemaFromHeaders(a['headers'] as Map, jsonDecode(a['body'] as String));
      expect(s.id.path, 'system/validation-sets');
      expect(s.builtIn, isTrue);
      expect(s.views.map((v) => v.name), ['admin', 'pinning-admin', 'state']);
      // Nested `content` rules are flattened to leaves with inherited access.
      final admin = s.view('admin')!;
      expect(admin.rules.first.request, '{account}.{set-name}.pinned-sequence');
      expect(admin.rules.first.storage, 'v1.{account}.{set-name}.pinned-sequence');
      expect(admin.rules.first.access, RuleAccess.write);
      expect(s.storage.lookup('v1'), isNotNull);
    });

    test('round-trips the sample storage schema', () {
      final json = jsonDecode(prettyStorageJson(networkRev4.storage));
      final back = decodeStorage(json);
      expect(
        back.leaves().map((l) => '${l.$1}:${describeLeaf(l.$2)}'),
        networkRev4.storage.leaves().map((l) => '${l.$1}:${describeLeaf(l.$2)}'),
      );
    });

    test('rejects malformed storage with a readable message', () {
      expect(() => decodeStorage({'storage': {}}), throwsA(isA<SchemaFormatException>()));
      expect(
        () => decodeStorage({
          'schema': {'a': '\${nope}'},
        }),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('secret visibility round-trips', () {
      final root = decodeStorage({
        'schema': {
          'psk': {'type': 'string', 'visibility': 'secret'},
          'ssid': 'string',
        },
      });
      expect(root.lookup('psk')!.secret, isTrue);
      expect(root.lookup('ssid')!.secret, isFalse);
      final json = encodeStorage(root);
      expect(((json['storage'] as Map)['schema'] as Map)['psk'], {'type': 'string', 'visibility': 'secret'});
      expect(decodeStorage(json).lookup('psk')!.secret, isTrue);
    });

    test('rejects secrets inside alias types', () {
      expect(
        () => decodeStorage({
          'aliases': {
            'creds': {
              'type': 'map',
              'schema': {
                'password': {'type': 'string', 'visibility': 'secret'},
              },
            },
          },
          'schema': {'login': '\${creds}'},
        }),
        throwsA(isA<SchemaFormatException>().having((e) => e.toString(), 'message', contains('alias'))),
      );
    });

    test('alternatives must agree on visibility', () {
      expect(
        () => decodeStorage({
          'schema': {
            'token': [
              {'type': 'string', 'visibility': 'secret'},
              'int',
            ],
          },
        }),
        throwsA(isA<SchemaFormatException>()),
      );
      final ok = decodeStorage({
        'schema': {
          'token': [
            {'type': 'string', 'visibility': 'secret'},
            {'type': 'int', 'visibility': 'secret'},
          ],
        },
      });
      expect(ok.lookup('token')!.secret, isTrue);
      expect(ok.lookup('token')!.alternatives, ['string', 'int']);
    });

    test('parses assertion text with YAML-style headers', () {
      final body = jsonEncode(encodeStorage(networkRev4.storage));
      final text =
          'type: confdb-schema\n'
          'authority-id: acme\n'
          'account-id: acme\n'
          'name: network\n'
          'revision: 4\n'
          'views:\n'
          '  wifi-admin:\n'
          '    rules:\n'
          '      -\n'
          '        request: ssid\n'
          '        storage: wifi.ssid\n'
          '        access: read-write\n'
          'body-length: ${body.length}\n'
          'sign-key-sha3-384: abc\n'
          '\n'
          '$body\n'
          '\n'
          'SIGNATURE';
      final s = parseAssertion(text);
      expect(s.id.path, 'acme/network');
      expect(s.revision, 4);
      expect(s.view('wifi-admin')!.rules.single.storage, 'wifi.ssid');
      expect(s.storage.lookup('wifi.band')!.choices, ['2.4GHz', '5GHz', 'auto']);
    });
  });

  group('lint and diff', () {
    test('draft rev 5 has the wifi.signal error and the proxy.https warning', () {
      final issues = lintSchema(networkDraft);
      expect(issues.where((i) => i.isError).single.storagePath, 'wifi.signal');
      expect(issues.where((i) => !i.isError).single.storagePath, 'proxy.https');
    });

    test('the quick fix suggests an ephemeral int and clears the error', () {
      final issue = lintSchema(networkDraft).firstWhere((i) => i.isError);
      expect(describeLeaf(issue.suggestedLeaf!), 'int, ephemeral');
      final fixed = networkDraft.copyWith(storage: networkDraft.storage.insert('wifi.signal', issue.suggestedLeaf!));
      expect(lintSchema(fixed).where((i) => i.isError), isEmpty);

      final diff = diffSchemas(networkRev4, fixed);
      expect(diff.where((d) => d.added).length, 3);
      expect(diff.where((d) => !d.added).single.what, 'band → wifi.band  ·  read-write');
    });
  });

  group('access', () {
    test('write to wifi.band runs custodian hooks, then the observer', () {
      final hooks = planWriteHooks(networkRev4, seedSnaps(), {'wifi.band', 'wifi.ssid'});
      expect(hooks.map((h) => '${h.snap} ${h.hook}'), [
        'net-manager change-view-wifi-admin',
        'net-manager save-view-wifi-admin',
        'wifi-indicator observe-view-wifi-state',
      ]);
    });

    test('browser-proxy stops at step 1 until its plug is connected', () async {
      final snap = seedSnaps().firstWhere((s) => s.name == 'browser-proxy');
      final d = await diagnoseAccess(
        snap: snap,
        storagePath: 'proxy.http',
        schemas: [networkRev4],
        readView: (_) => throw UnimplementedError(),
      );
      expect(d.failedStep, 1);
      expect(d.checks.first.fixConnect?.id, 'browser-proxy:proxy-state');

      final connected = snap.copyWith(plugs: [snap.plugs.single.copyWith(state: ConnState.connected)]);
      final ok = await diagnoseAccess(
        snap: connected,
        storagePath: 'proxy.http',
        schemas: [networkRev4],
        readView: (_) => throw UnimplementedError(),
      );
      expect(ok.ok, isTrue);
    });

    test('playground: net-manager is allowed, browser-proxy is denied at step 2', () async {
      final snaps = seedSnaps();
      Future<SimResult> run(String snap) => simulate(
        SimRequest(draft: networkDraft, view: 'wifi-admin', path: 'ssid', isSet: false, snap: snaps.firstWhere((s) => s.name == snap)),
        snaps: snaps,
        readCurrent: (_) async => null,
      );
      expect((await run('net-manager')).allowed, isTrue);
      expect((await run('browser-proxy')).deniedAt, 2);
    });
  });

  group('values', () {
    test('validates enums, ranges and hints', () {
      const band = StorageNode(key: 'band', kind: StorageKind.string, choices: ['2.4GHz', '5GHz', 'auto']);
      expect(validateValue(band, '5GHz'), isNull);
      expect(validateValue(band, '6GHz'), contains('one of'));
      expect(validateValue(const StorageNode(key: 'n', kind: StorageKind.int, min: 0, max: 100), '101'), contains('at most'));
      expect(
        validateValue(
          const StorageNode(key: 'psk', kind: StorageKind.string),
          'abc',
          hint: valueHints['wifi.psk'],
        ),
        contains('at least 8'),
      );
    });

    test('builds snap set commands, masking secrets', () {
      const ref = ViewRef('acme', 'network', 'wifi-admin');
      expect(
        snapSetCommand(ref, [('band', '5GHz', false), ('ssid', 'acme-office-5g', false)]),
        'sudo snap set acme/network/wifi-admin band=5GHz ssid=acme-office-5g',
      );
      expect(snapSetCommand(ref, [('psk', 'secret', true)]), 'sudo snap set acme/network/wifi-admin psk=<value>');
    });
  });

  group('fake repository', () {
    test('net-manager rejects a short psk and nothing changes', () async {
      final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
      const ref = ViewRef('acme', 'network', 'wifi-admin');
      final rejected = await repo.applyValues(ref, {'psk': 'abc', 'band': '5GHz'});
      expect(rejected.status, ChangeStatus.error);
      expect(rejected.rejectedBy, 'net-manager');
      final band = (await repo.readView(ref)).entries.firstWhere((e) => e.key == 'band');
      expect(band.value, 'auto');

      final done = await repo.applyValues(ref, {'band': '5GHz'});
      expect(done.status, ChangeStatus.done);
      expect(done.id, rejected.id + 1);
      expect((await repo.readView(ref)).entries.firstWhere((e) => e.key == 'band').value, '5GHz');
    });

    test('write-only values are never read back', () async {
      final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
      final psk = (await repo.readView(const ViewRef('acme', 'network', 'wifi-admin'))).entries.firstWhere((e) => e.key == 'psk');
      expect(psk.hasValue, isTrue);
      expect(psk.value, isNull);
    });

    test('secret values are left out of reads', () async {
      final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
      final snapshot = await repo.readView(const ViewRef('acme', 'network', 'wifi-admin'));
      final psk = snapshot.entries.firstWhere((e) => e.key == 'psk');
      expect(psk.secret, isTrue);
      expect(psk.masked, isTrue);
      expect(psk.value, isNull);
    });
  });
}
