import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/schema_codec.dart';
import '../app_data.dart';
import '../models.dart';
import 'rust_auth_client.dart';
import 'store_auth_client.dart';

/// The Snap Store's confdb-schemas API (`/api/v2/confdb-schemas` on the
/// dashboard), reached through the vendored `rust/` `snapstore-auth` crate
/// (see [RustAuthClient]), which handles Ubuntu One SSO login, 2FA, and
/// macaroon-signed requests.
///
/// The saved login is kept in `store.json` under [appDataPath] (readable
/// only by the user), replacing the old surl-based `store.surl`.
class SnapStoreClient {
  SnapStoreClient({StoreAuthClient? authClient, String? authFile})
    : authClient = authClient ?? RustAuthClient(),
      authFile = authFile ?? appDataPath('store.json');

  final StoreAuthClient authClient;
  final String authFile;

  static const _api = '/api/v2/confdb-schemas';

  /// `{env, credentials_json}` from [authFile], or `null` when there's no
  /// saved login.
  Map<String, Object?>? _readSaved() {
    final file = File(authFile);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      return json is Map ? json.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _save(StoreEnv env, String credentialsJson) async {
    final file = File(authFile);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'env': env.name, 'credentials_json': credentialsJson}));
    try {
      await Process.run('chmod', ['600', authFile]);
    } on ProcessException {
      // Best-effort: the file still works, just without the tightened mode.
    }
  }

  Future<void> _forget() async {
    final file = File(authFile);
    if (file.existsSync()) await file.delete();
  }

  /// The saved login, checked with the Store; signed out when there is none
  /// or the Store rejects it.
  Future<StoreSession> session() async {
    final saved = _readSaved();
    if (saved == null) return const StoreSession.signedOut();
    final env = StoreEnv.parse(saved['env'] as String?);
    final credentialsJson = saved['credentials_json'] as String? ?? '';
    try {
      final restored = await authClient.restoreCredentials(env: env, credentialsJson: credentialsJson);
      return _session(env, restored.account);
    } on ConfdbException catch (e) {
      if (e.kind == ConfdbErrorKind.signedOut) {
        return StoreSession.signedOut(detail: 'The saved Snap Store login has expired. Sign in again.');
      }
      rethrow;
    }
  }

  static StoreSession _session(StoreEnv env, StoreAccountInfo account) =>
      StoreSession(env: env, username: account.username, email: account.email, accountId: account.id);

  /// Ubuntu One login for [env]. Throws with [ConfdbErrorKind.twoFactorRequired]
  /// when the account needs a one-time code and [otp] is missing.
  Future<StoreSession> login({required String email, required String password, String? otp, StoreEnv env = StoreEnv.production}) async {
    final result = await authClient.login(env: env, email: email, password: password, otp: otp);
    await _save(env, result.credentialsJson);
    return _session(env, result.account);
  }

  Future<void> logout() async {
    await _forget();
    try {
      await authClient.logout();
    } on ConfdbException {
      // Best-effort: the saved login is already gone either way.
    }
  }

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
    final r = await authClient.request(method, path, body: body, contentType: contentType);
    if (!ok.contains(r.status)) throw _error(r.status, r.body);
    return r.body.trim().isEmpty ? null : jsonDecode(r.body);
  }

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
