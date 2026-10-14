import 'dart:io';

import 'package:confdb_studio/data/drafts/file_draft_store.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:confdb_studio/data/snapd/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with [response] and records what it was asked.
class _Recording implements SnapdTransport {
  _Recording(this.response);
  final SnapdResponse response;
  final calls = <(String, String, Object?)>[];

  @override
  String get name => 'recording';

  @override
  Future<SnapdResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? rawBody,
    String contentType = 'application/json',
    bool interactive = false,
  }) async {
    calls.add((method, path, rawBody ?? body));
    return response;
  }

  @override
  void close() {}
}

const _denied = SnapdResponse(type: 'error', statusCode: 401, result: {'message': 'access denied', 'kind': 'login-required'});
const _ok = SnapdResponse(type: 'sync', statusCode: 200, result: null);

/// A stand-in `snap`: `sign` prints a signed schema; `known --remote` prints
/// the store's account and account-key (or fails when [keyOwner] is null).
String _snapStub(String? keyOwner) {
  final accountKey = keyOwner == null
      ? 'echo "error: assertion not found" >&2; exit 1'
      : "printf 'type: account-key\\naccount-id: $keyOwner\\npublic-key-sha3-384: KEYSHA\\n\\nBODY\\n'";
  return [
    '#!/bin/sh',
    r'case "$1 $3" in',
    r"  'sign '*) cat >/dev/null; printf 'type: confdb-schema\nauthority-id: acme\naccount-id: acme\nname: network\nsign-key-sha3-384: KEYSHA\n\n{}\n\nSIG\n' ;;",
    "  'known account-key') $accountKey ;;",
    r"  'known account') printf 'type: account\naccount-id: acme\n\nSIG\n' ;;",
    'esac',
    '',
  ].join('\n');
}

void main() {
  writeErrorTests();
  test('a write snapd refuses over the socket is retried as root', () async {
    final socket = _Recording(_denied);
    final root = _Recording(_ok);
    await SnapdRepository(socket, elevated: root).enableConfdb();
    expect(socket.calls.single.$1, 'PUT');
    final (method, path, body) = root.calls.single;
    expect((method, path), ('PUT', '/v2/snaps/system/conf'));
    expect(body, {'experimental.confdb': true});
  });

  test('other errors are reported, not retried', () async {
    final socket = _Recording(const SnapdResponse(type: 'error', statusCode: 400, result: {'message': 'bad request'}));
    final root = _Recording(_ok);
    await expectLater(SnapdRepository(socket, elevated: root).enableConfdb(), throwsA(isA<ConfdbException>()));
    expect(root.calls, isEmpty);
  });

  group('acknowledging a signed schema', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ack'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<(_Recording, Object?)> run({required String? keyOwner}) async {
      final snap = File('${dir.path}/snap')..writeAsStringSync(_snapStub(keyOwner));
      await Process.run('chmod', ['+x', snap.path]);
      final socket = _Recording(_ok);
      final repo = SnapdRepository(
        socket,
        snapCommand: snap.path,
        drafts: FileDraftStore(dir: Directory('${dir.path}/drafts')),
      );
      try {
        await repo.signAndAcknowledge(networkDraft, const SigningKey(name: 'acme-release', sha3384: 'KEYSHA'));
        return (socket, null);
      } catch (e) {
        return (socket, e);
      }
    }

    List<String?> acked(_Recording socket) => [
      for (final c in socket.calls)
        if (c.$2 == '/v2/assertions') SnapdRepository.assertionHeaders(c.$3! as String)['type'],
    ];

    test('acknowledges the account and account-key before the schema', () async {
      final (socket, error) = await run(keyOwner: 'acme');
      expect(error, isNull);
      expect(acked(socket), ['account', 'account-key', 'confdb-schema']);
    });

    test('explains an unregistered key', () async {
      final (socket, error) = await run(keyOwner: null);
      expect('$error', contains('isn’t registered in the Snap Store'));
      expect((error! as ConfdbException).command, 'snapcraft register-key acme-release');
      expect(acked(socket), isEmpty);
    });

    test('explains a key owned by another account', () async {
      final (socket, error) = await run(keyOwner: 'someone-else');
      expect('$error', contains('belongs to account `someone-else`'));
      expect(acked(socket), isEmpty);
    });
  });

  test('confdb writes use the same body as snap set', () async {
    // Matches `snap set <view> band=5GHz` on snapd 2.77.1 (traced with strace).
    final socket = _AsyncDone();
    final repo = SnapdRepository(socket, elevated: _Recording(_ok));
    await repo.applyValues(const ViewRef('acme', 'network', 'wifi-admin'), {'band': '5GHz', 'ssid': null});
    final put = socket.calls.firstWhere((c) => c.$1 == 'PUT');
    expect(put.$2, '/v2/confdb/acme/network/wifi-admin');
    expect(put.$3, {
      'values': {'band': '5GHz', 'ssid': null},
    });
  });
}

/// Starts a change for writes and reports it done; reads see no schemas.
class _AsyncDone extends _Recording {
  _AsyncDone() : super(_ok);

  @override
  Future<SnapdResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? rawBody,
    String contentType = 'application/json',
    bool interactive = false,
  }) async {
    calls.add((method, path, rawBody ?? body));
    if (method == 'PUT') return const SnapdResponse(type: 'async', statusCode: 202, result: null, change: '7');
    if (path == '/v2/changes/7') {
      return const SnapdResponse(
        type: 'sync',
        statusCode: 200,
        result: {'id': '7', 'kind': 'set-confdb', 'summary': 'Set confdb', 'status': 'Done', 'ready': true},
      );
    }
    if (path.startsWith('/v2/connections')) return const SnapdResponse(type: 'sync', statusCode: 200, result: <String, Object?>{});
    if (path.startsWith('/v2/assertions')) return const SnapdResponse(type: 'sync', statusCode: 200, result: <Object?>[]);
    return _ok;
  }
}

/// Serves one acknowledged `acme/settings` schema, as `/v2/assertions` does.
class _Assertions extends _Recording {
  _Assertions(this.rules) : super(_ok);
  final List<Map<String, String>> rules;

  @override
  Future<SnapdResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? rawBody,
    String contentType = 'application/json',
    bool interactive = false,
  }) async {
    if (!path.startsWith('/v2/assertions')) return _ok;
    return SnapdResponse(
      type: 'sync',
      statusCode: 200,
      result: [
        {
          'headers': {
            'type': 'confdb-schema',
            'authority-id': 'acme',
            'account-id': 'acme',
            'name': 'settings',
            'revision': '2',
            'views': {
              'admin': {'rules': rules},
            },
          },
          'body': '{"storage": {"schema": {"config": {"schema": {"name": "string"}}}}}',
        },
      ],
    );
  }
}

void writeErrorTests() {
  const ref = ViewRef('acme', 'settings', 'admin');
  const snapdError = ConfdbException('snapd: cannot write data: cannot accept top level element: map contains unexpected key "values".');

  test('explains data left over from an earlier revision', () async {
    final repo = SnapdRepository(
      _Assertions([
        {'request': 'name', 'storage': 'config.name', 'access': 'read-write'},
      ]),
    );
    final e = await repo.explainWriteError(snapdError, ref);
    expect(e.message, contains('This device has data stored under `values`'));
    expect(e.message, contains('revision 2'));
    expect(e.command, 'snap known confdb-schema account-id=acme name=settings');
  });

  test('explains a rule that stores outside the storage schema', () async {
    final repo = SnapdRepository(
      _Assertions([
        {'request': '{key}', 'storage': 'values.{key}', 'access': 'read-write'},
      ]),
    );
    final e = await repo.explainWriteError(snapdError, ref);
    expect(e.message, contains('view `admin` has rules that store under `values`'));
  });

  test('leaves other errors alone', () async {
    final repo = SnapdRepository(_Assertions(const []));
    const other = ConfdbException('snapd: something else.');
    expect(identical(await repo.explainWriteError(other, ref), other), isTrue);
  });
}
