import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/schema_codec.dart';
import '../models.dart';

/// The Snap Store's confdb-schemas API (`/api/v2/confdb-schemas` on the
/// dashboard), called through `tool/store_helper.py`, which signs requests
/// with surl's stored macaroons.
///
/// Where things are, from the environment (the snap sets them):
/// * `CONFDB_STORE_PYTHON` – a Python with surl importable (default `python3`).
/// * `CONFDB_STORE_PYTHONPATH` – where surl's venv keeps its packages.
/// * `CONFDB_STORE_HELPER` – the helper script (default `tool/store_helper.py`).
/// * `CONFDB_STORE_AUTH` – the saved login (default
///   `$XDG_DATA_HOME/confdb-studio/store.surl`), readable only by the user.
class SnapStoreClient {
  SnapStoreClient({String? python, String? helper, String? pythonPath, String? authFile, this.timeout = const Duration(seconds: 90)})
    : python = python ?? _env('CONFDB_STORE_PYTHON') ?? 'python3',
      helper = helper ?? _env('CONFDB_STORE_HELPER') ?? 'tool/store_helper.py',
      pythonPath = pythonPath ?? _env('CONFDB_STORE_PYTHONPATH'),
      authFile = authFile ?? _env('CONFDB_STORE_AUTH') ?? _defaultAuthFile();

  final String python;
  final String helper;
  final String? pythonPath;
  final String authFile;
  final Duration timeout;

  static String? _env(String name) {
    final v = Platform.environment[name];
    return v == null || v.isEmpty ? null : v;
  }

  static String _defaultAuthFile() {
    final env = Platform.environment;
    final base = env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? '.'}/.local/share';
    return '$base/confdb-studio/store.surl';
  }

  static const _api = '/api/v2/confdb-schemas';

  /// Runs the helper; returns its `{status, body}` or throws its error.
  Future<({int status, String body, StoreEnv env})> _run(List<String> args, {String? stdin}) async {
    final Process proc;
    try {
      proc = await Process.start(
        python,
        [helper, ...args],
        environment: {
          'CONFDB_STORE_AUTH': authFile,
          'PYTHONNOUSERSITE': '1',
          // Empty counts as unset: don't let the host's Python home leak in.
          'PYTHONHOME': '',
          'PYTHONPATH': ?pythonPath,
        },
      );
    } on ProcessException catch (e) {
      throw ConfdbException('Couldn’t run the Snap Store helper (`$python`): ${e.message}', kind: ConfdbErrorKind.unsupported);
    }
    proc.stdin.write(stdin ?? '');
    await proc.stdin.close();
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      throw const ConfdbException('The Snap Store didn’t answer in time.', kind: ConfdbErrorKind.offline);
    }
    final Map result;
    try {
      result = jsonDecode((await out).trim()) as Map;
    } on Object {
      final detail = (await err).trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      final missing = detail != null && detail.contains('ModuleNotFoundError');
      throw ConfdbException(
        missing
            ? 'surl isn’t available to the Snap Store helper ($detail).'
            : 'The Snap Store helper failed${code == 0 ? '' : ' (exit $code)'}${detail == null ? '.' : ': $detail'}',
        kind: ConfdbErrorKind.unsupported,
      );
    }
    final error = result['error'];
    if (error != null) {
      throw ConfdbException('$error', kind: _kind('${result['code']}'));
    }
    return (status: result['status'] as int? ?? 0, body: result['body'] as String? ?? '', env: StoreEnv.parse(result['store'] as String?));
  }

  static ConfdbErrorKind _kind(String code) => switch (code) {
    'not-logged-in' => ConfdbErrorKind.signedOut,
    'twofactor-required' => ConfdbErrorKind.twoFactorRequired,
    'offline' => ConfdbErrorKind.offline,
    'invalid-credentials' || 'twofactor-failed' => ConfdbErrorKind.permissionDenied,
    _ => ConfdbErrorKind.other,
  };

  /// A Store answer that isn't a success, as a [ConfdbException]. The Store
  /// reports problems as `{"error-list": [{"code", "message"}]}`.
  static ConfdbException _error(int status, String body) {
    String? message;
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final list = json['error-list'];
        if (list is List && list.isNotEmpty) {
          message = [for (final e in list.whereType<Map>()) '${e['message'] ?? e['code']}'.trim()].join('\n');
        }
        message ??= (json['title'] ?? json['detail'] ?? json['message']) as String?;
      }
    } on FormatException {
      // Not JSON: fall back to the status.
    }
    if (status == 401) {
      return ConfdbException(
        'The Snap Store login has expired or was revoked. Sign in again.${message == null ? '' : '\n$message'}',
        kind: ConfdbErrorKind.signedOut,
      );
    }
    final text = message ?? 'The Snap Store answered $status.';
    return ConfdbException('Snap Store: ${text.trimRight()}', kind: status == 404 ? ConfdbErrorKind.notFound : ConfdbErrorKind.other);
  }

  Future<Object?> _request(String method, String path, {String? body, String? contentType, Set<int> ok = const {200}}) async {
    final r = await _run(['request', method, path, ?contentType], stdin: body);
    if (!ok.contains(r.status)) throw _error(r.status, r.body);
    return r.body.trim().isEmpty ? null : jsonDecode(r.body);
  }

  /// `/api/v2/tokens/whoami`: `{"account": {"username", "email", "id", …}}`.
  static StoreSession _session(StoreEnv env, String body) {
    final json = jsonDecode(body);
    final account = json is Map ? json['account'] as Map? ?? const {} : const {};
    String? field(String k) => '${account[k] ?? ''}'.trim().isEmpty ? null : '${account[k]}'.trim();
    return StoreSession(env: env, username: field('username'), email: field('email'), accountId: field('id') ?? field('account-id'));
  }

  /// The saved login, checked with the Store; signed out when there is none
  /// or the Store rejects it.
  Future<StoreSession> session() async {
    final ({int status, String body, StoreEnv env}) r;
    try {
      r = await _run(['whoami']);
    } on ConfdbException catch (e) {
      if (e.kind == ConfdbErrorKind.signedOut) return const StoreSession.signedOut();
      rethrow;
    }
    if (r.status == 401) return const StoreSession.signedOut(detail: 'The saved Snap Store login has expired. Sign in again.');
    if (r.status != 200) throw _error(r.status, r.body);
    return _session(r.env, r.body);
  }

  /// Ubuntu One login for [env]. Throws with [ConfdbErrorKind.twoFactorRequired]
  /// when the account needs a one-time code and [otp] is missing.
  Future<StoreSession> login({required String email, required String password, String? otp, StoreEnv env = StoreEnv.production}) async {
    final r = await _run(['login'], stdin: jsonEncode({'email': email, 'password': password, 'otp': ?otp, 'store': env.name}));
    if (r.status != 200) throw _error(r.status, r.body);
    return _session(r.env, r.body);
  }

  Future<void> logout() async => _run(['logout']);

  /// Every confdb-schema the signed-in account registered, at its latest
  /// revision.
  Future<List<ConfdbSchema>> listSchemas() async => _assertions(await _request('GET', _api));

  static List<ConfdbSchema> _assertions(Object? json) {
    final list = json is Map ? json['assertions'] as List? ?? const [] : const [];
    return [for (final a in list.whereType<Map>()) ?_fromStore(a)];
  }

  /// One `{headers, body}` item. The documented headers leave out `revision`;
  /// it's read when the Store sends it.
  static ConfdbSchema? _fromStore(Map item) {
    final headers = item['headers'] as Map? ?? const {};
    final body = item['body'] as String? ?? '';
    final ConfdbSchema s;
    try {
      s = schemaFromHeaders(headers, body.trim().isEmpty ? null : jsonDecode(body));
    } on Object {
      return null;
    }
    return ConfdbSchema(
      id: s.id,
      revision: headers.containsKey('revision') ? s.revision : null,
      summary: s.summary,
      views: s.views,
      storage: s.storage,
      signedBy: s.signedBy,
    );
  }

  /// `build-assertion`: the Store's headers for [draft], ready for `snap sign`.
  Future<Map<String, Object?>> buildAssertion(ConfdbSchema draft) async {
    final input = signInput(draft, revision: 0, timestamp: DateTime.now());
    final json = await _request(
      'POST',
      '$_api/build-assertion',
      contentType: 'application/json',
      body: jsonEncode({
        for (final k in ['account-id', 'name', 'summary', 'views', 'body', 'timestamp'])
          if (input.containsKey(k)) k: input[k],
      }),
    );
    if (json is! Map) throw const ConfdbException('Snap Store: build-assertion returned no headers.');
    return json.cast<String, Object?>();
  }

  /// Registers a signed confdb-schema [assertion]; returns what the Store
  /// now has.
  Future<ConfdbSchema?> register(String assertion) async {
    final json = await _request('POST', _api, body: assertion, contentType: 'application/x.ubuntu.assertion', ok: const {200, 201});
    return _assertions(json).firstOrNull;
  }
}
