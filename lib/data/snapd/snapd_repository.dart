import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/analysis.dart';
import '../../domain/paths.dart';
import '../../domain/schema_codec.dart';
import '../../domain/values.dart';
import '../confdb_repository.dart';
import '../drafts/file_draft_store.dart';
import '../models.dart';
import '../store/snap_store_client.dart';
import 'transport.dart';

/// Backend for a real snapd, over either [SnapdTransport].
///
/// Endpoints: `/v2/system-info` (version, `confdb` feature), `/v2/assertions`,
/// `/v2/confdb/<account>/<schema>/<view>`, `/v2/changes`, `/v2/connections`,
/// `/v2/interfaces`, `/v2/snaps`. Signing uses `snap sign` and `snap keys`,
/// because keys live in the user's keyring, not in snapd.
class SnapdRepository implements ConfdbRepository {
  SnapdRepository(
    this.transport, {
    FileDraftStore? drafts,
    this.snapCommand = 'snap',
    this.snapcraftCommand = 'snapcraft',
    SnapdTransport? elevated,
    Future<List<String>?> Function(String snap)? readHooks,
    SnapStoreClient? store,
  }) : store = store ?? SnapStoreClient(),
       _readHooks = readHooks ?? _hooksOnDisk,
       _drafts = drafts ?? FileDraftStore(),
       _elevated = elevated ?? SnapCommandTransport(snap: snapCommand);

  final SnapdTransport transport;

  /// The Snap Store's confdb-schemas API, through the vendored Rust backend.
  final SnapStoreClient store;

  /// The hooks a snap ships, or null when they can't be read.
  final Future<List<String>?> Function(String snap) _readHooks;

  /// snapd takes a snap's hooks from the executables in its `meta/hooks`,
  /// which installed snaps expose world-readable under /snap.
  static Future<List<String>?> _hooksOnDisk(String snap) async {
    final dir = Directory('/snap/$snap/current/meta/hooks');
    try {
      if (!await dir.exists()) return const [];
      return [await for (final e in dir.list()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)];
    } on FileSystemException {
      return null;
    }
  }

  /// Runs writes as root (`pkexec snap debug api`) when snapd refuses them on
  /// [transport]: some endpoints, like installing assertions, accept only root,
  /// not a polkit prompt.
  final SnapdTransport _elevated;
  final String snapCommand;
  final String snapcraftCommand;
  final FileDraftStore _drafts;
  final _events = StreamController<void>.broadcast();

  @override
  String get backendName => transport.name;

  @override
  Stream<void> get onChanged => _events.stream;

  void _notify() => _events.add(null);

  static bool _denied(SnapdResponse res) =>
      res.statusCode == 401 || res.statusCode == 403 || res.errorKind == 'login-required' || res.errorKind == 'auth-cancelled';

  /// A write that needs admin rights: tries [transport] (which may show a
  /// polkit prompt), then retries as root if snapd still refuses.
  Future<SnapdResponse> _write(String method, String path, {Object? body, String? rawBody, String contentType = 'application/json'}) async {
    final res = await transport.request(method, path, body: body, rawBody: rawBody, contentType: contentType, interactive: true);
    if (!res.isError || !_denied(res) || identical(transport, _elevated) || transport is SnapCommandTransport) return res;
    return _elevated.request(method, path, body: body, rawBody: rawBody, contentType: contentType, interactive: true);
  }

  Future<Object?> _sync(String method, String path, {Map<String, String>? query, Object? body, bool interactive = false}) async {
    final res = await transport.request(method, path, query: query, body: body, interactive: interactive);
    if (res.isError) throw _error(res, path);
    return res.result;
  }

  ConfdbException _error(SnapdResponse res, String path) {
    final kind = switch (res.errorKind) {
      'login-required' => ConfdbErrorKind.permissionDenied,
      'auth-cancelled' => ConfdbErrorKind.permissionDenied,
      _ when res.statusCode == 401 || res.statusCode == 403 => ConfdbErrorKind.permissionDenied,
      _ when res.statusCode == 404 => ConfdbErrorKind.notFound,
      _ => ConfdbErrorKind.other,
    };
    final hint = kind == ConfdbErrorKind.permissionDenied ? ' Authenticate as an administrator to continue.' : '';
    final msg = res.errorMessage.trimRight();
    return ConfdbException('snapd: $msg${msg.endsWith('.') ? '' : '.'}$hint', kind: kind);
  }

  /// Waits for an async change to be ready, then returns it.
  Future<Map> _waitChange(String id, {Duration timeout = const Duration(minutes: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final c = await _sync('GET', '/v2/changes/$id') as Map;
      if (c['ready'] == true) return c;
      if (DateTime.now().isAfter(deadline)) throw ConfdbException('Change $id is still running.', command: 'snap watch $id');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<ConfdbChange> _asyncChange(String method, String path, Object? body) async {
    final res = await _write(method, path, body: body);
    if (res.isError) throw _error(res, path);
    final id = res.change;
    if (id == null) throw const ConfdbException('snapd didn’t start a change.');
    final c = await _waitChange(id);
    _notify();
    return _change(c, await _confdbPlugs());
  }

  // ---------------------------------------------------------------- system

  @override
  Future<SystemStatus> systemStatus() async {
    final info = await _sync('GET', '/v2/system-info') as Map;
    final features = info['features'] as Map? ?? const {};
    final confdb = (features['confdb'] ?? features['registries']) as Map?;
    return SystemStatus(snapdVersion: info['version'] as String? ?? '?', confdbEnabled: confdb?['enabled'] == true);
  }

  @override
  Future<void> enableConfdb() async {
    final res = await _write('PUT', '/v2/snaps/system/conf', body: {'experimental.confdb': true});
    if (res.isError) throw _error(res, 'system conf');
    if (res.change != null) await _waitChange(res.change!);
    _notify();
  }

  @override
  Future<String?> developerAccount() async {
    final fromEnv = Platform.environment['CONFDB_ACCOUNT'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    final store = await storeAccount();
    if (store.accountId != null) return store.accountId;
    try {
      final own = [...await listDrafts(), ...await listSchemas()].where((s) => !s.builtIn);
      return own.firstOrNull?.id.account;
    } on ConfdbException {
      return null;
    }
  }

  /// `snapcraft whoami`: exit 0 with `key: value` lines when logged in,
  /// non-zero with "No credentials found" when not.
  @override
  Future<StoreAccount> storeAccount() async {
    final ProcessResult r;
    try {
      r = await Process.run(snapcraftCommand, ['whoami']).timeout(const Duration(seconds: 30));
    } on ProcessException {
      return const StoreAccount.unavailable(detail: 'snapcraft isn’t installed.');
    } on TimeoutException {
      return const StoreAccount.unavailable(detail: '`snapcraft whoami` didn’t answer.');
    }
    final out = '${r.stdout}';
    if (r.exitCode != 0) {
      final err = '${r.stderr}\n$out'
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('Full execution log'))
          .firstOrNull;
      return StoreAccount.loggedOut(detail: err);
    }
    final fields = <String, String>{
      for (final line in out.split('\n'))
        if (line.contains(':')) line.substring(0, line.indexOf(':')).trim().toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
    };
    String? field(String k) => (fields[k]?.isEmpty ?? true) ? null : fields[k];
    return StoreAccount(login: StoreLogin.loggedIn, username: field('username'), email: field('email'), accountId: field('id'));
  }

  /// `snap known account account-id=<id>`, then `--remote`.
  @override
  Future<AccountInfo?> account(String accountId) async {
    for (final remote in [false, true]) {
      final SnapdResponse res;
      try {
        res = await transport.request(
          'GET',
          '/v2/assertions/account',
          query: {'json': 'true', 'account-id': accountId, if (remote) 'remote': 'true'},
        );
      } on Exception {
        // Offline, or snapd too old to query: show the ID itself.
        continue;
      }
      if (res.isError) continue;
      final headers = (res.result as List? ?? const []).whereType<Map>().map((a) => a['headers']).whereType<Map>().firstOrNull;
      if (headers == null) continue;
      String? field(String k) => (headers[k] as String?)?.trim().isEmpty ?? true ? null : (headers[k] as String).trim();
      return AccountInfo(id: accountId, username: field('username'), displayName: field('display-name'));
    }
    return null;
  }

  // --------------------------------------------------------------- schemas

  @override
  Future<List<ConfdbSchema>> listSchemas() async {
    final res = await transport.request('GET', '/v2/assertions/confdb-schema', query: {'json': 'true'});
    if (res.isError) {
      if (res.statusCode == 404) return const [];
      throw _error(res, 'assertions');
    }
    final schemas = <ConfdbSchema>[];
    for (final a in (res.result as List? ?? const [])) {
      final headers = (a as Map)['headers'] as Map;
      final body = a['body'] as String?;
      try {
        schemas.add(schemaFromHeaders(headers, body == null || body.isEmpty ? null : jsonDecode(body)));
      } on SchemaFormatException {
        // Skip assertions in a format this version can't read.
      }
    }
    // A newer revision of the same schema supersedes older ones.
    final latest = <SchemaId, ConfdbSchema>{};
    for (final s in schemas) {
      final prev = latest[s.id];
      if (prev == null || (s.revision ?? 0) > (prev.revision ?? 0)) latest[s.id] = s;
    }
    return latest.values.toList();
  }

  @override
  Future<List<ConfdbSchema>> listDrafts() => _drafts.list();

  @override
  Future<void> saveDraft(ConfdbSchema draft) async {
    await _drafts.save(draft);
    _notify();
  }

  @override
  Future<void> discardDraft(SchemaId id) async {
    await _drafts.discard(id);
    _notify();
  }

  @override
  Future<ConfdbSchema> importSchema(String filePath) async {
    final parsed = parseSchemaFile(await File(filePath).readAsString());
    final existing = (await listSchemas()).where((s) => s.id == parsed.id).firstOrNull;
    final draft = ConfdbSchema(
      id: parsed.id,
      summary: parsed.summary,
      views: parsed.views,
      storage: parsed.storage,
      isDraft: true,
      baseRevision: existing?.revision,
    );
    await saveDraft(draft);
    return draft;
  }

  // ---------------------------------------------------------------- values

  Future<ConfdbSchema> _schema(SchemaId id) async {
    final s = (await listSchemas()).where((s) => s.id == id).firstOrNull;
    if (s == null) throw ConfdbException('No confdb-schema ${id.path} is acknowledged on this device.', kind: ConfdbErrorKind.notFound);
    return s;
  }

  @override
  Future<ViewSnapshot> readView(ViewRef ref) async {
    final schema = await _schema(ref.schemaId);
    final view = schema.view(ref.view);
    if (view == null) throw ConfdbException('No view ${ref.path}', kind: ConfdbErrorKind.notFound);

    Map values = const {};
    HookFailure? failure;
    // Same request as `snap get <view>`: an empty `keys` reads everything.
    final res = await transport.request('GET', '/v2/confdb/${ref.path}', query: {'keys': ''}, interactive: true);
    if (res.isError) {
      final msg = res.errorMessage;
      final notFound =
          res.statusCode == 404 || res.errorKind.contains('not-found') || msg.contains('no value') || msg.contains('not found');
      if (!notFound) {
        if (msg.contains('load-view')) {
          failure = HookFailure(snap: 'custodian', hook: RegExp(r'load-view-[\w-]+').firstMatch(msg)?[0] ?? 'load-view', message: msg);
        } else {
          throw _error(res, ref.path);
        }
      }
    } else if (res.type == 'async' && res.change != null) {
      // Reads that load ephemeral values run hooks in a change.
      final c = await _waitChange(res.change!);
      final data = c['data'] as Map? ?? const {};
      if (c['status'] == 'Error') {
        final msg = c['err'] as String? ?? 'load-view hook failed';
        failure = HookFailure(snap: 'custodian', hook: RegExp(r'load-view-[\w-]+').firstMatch(msg)?[0] ?? 'load-view', message: msg);
      }
      values = (data['values'] ?? (data.length == 1 ? data.values.first : data)) as Map? ?? const {};
    } else {
      values = res.result as Map? ?? const {};
    }

    final entries = [
      for (final rule in view.rules)
        () {
          final node = resolveStoragePath(schema.storage, rule.storage);
          // A placeholder rule gets the whole collection (e.g. every sensor).
          final (has, value) = lookupValue(values, rule.request);
          final ephemeralFailed = failure != null && (node?.ephemeral ?? false);
          return ViewEntry(
            rule: rule,
            node: node,
            value: rule.access.canRead ? value : null,
            // Write-only paths can't be read and snapd leaves secrets out for
            // non-admins, so whether they are set is unknown.
            hasValue: has || !rule.access.canRead || (node?.secret ?? false),
            loadError: ephemeralFailed ? failure.message : null,
          );
        }(),
    ];
    return ViewSnapshot(ref: ref, schema: schema, entries: entries, loadFailure: failure);
  }

  /// snapd validates all stored data against the acknowledged schema on every
  /// write. "unexpected key" means the data or a rule doesn't fit the current
  /// revision; say which, using the schema as snapd has it now.
  Future<ConfdbException> explainWriteError(ConfdbException e, ViewRef ref) async {
    final key = RegExp(r'unexpected key "?([^"\s]+)"?').firstMatch(e.message)?[1];
    if (key == null) return e;
    final ConfdbSchema schema;
    try {
      schema = await _schema(ref.schemaId);
    } on ConfdbException {
      return e;
    }
    final inStorage = schema.storage.children.any((c) => c.key == key);
    final ruleUsesKey = schema.view(ref.view)?.rules.any((r) => r.storage.split('.').first == key) ?? false;
    final rev = schema.revision == null ? 'the acknowledged revision' : 'revision ${schema.revision}';
    final known = 'snap known confdb-schema account-id=${ref.account} name=${ref.schema}';
    if (ruleUsesKey && !inStorage) {
      return ConfdbException(
        '${e.message}\n\nIn $rev of `${ref.schemaId.path}`, view `${ref.view}` has rules that store under `$key`, '
        'but the storage schema doesn’t define `$key`. Add `$key` to the storage (or change those rules) and sign a new revision.',
        command: known,
        kind: e.kind,
      );
    }
    if (!inStorage) {
      return ConfdbException(
        '${e.message}\n\nThis device has data stored under `$key`, probably written with an earlier revision. '
        '$rev of `${ref.schemaId.path}` no longer defines `$key`, and snapd checks all stored data on every write, so writes fail. '
        'To recover, sign a revision that defines `$key` again (with a view rule that can write it), unset the old values '
        'through that view, then remove `$key` in a later revision.',
        command: known,
        kind: e.kind,
      );
    }
    return e;
  }

  @override
  Future<ConfdbChange> applyValues(ViewRef ref, Map<String, Object?> values) async {
    // Read the current values first so the change can show before/after.
    ViewSnapshot? before;
    try {
      before = await readView(ref);
    } on ConfdbException {
      before = null;
    }
    // Same body as `snap set <view> k=v` (and `snap unset`, with null values).
    final ConfdbChange change;
    try {
      change = await _asyncChange('PUT', '/v2/confdb/${ref.path}', {'values': values});
    } on ConfdbException catch (e) {
      throw await explainWriteError(e, ref);
    }
    final view = before?.view;
    return change.withValues([
      for (final e in values.entries)
        () {
          final entry = before?.entries.where((x) => x.key == e.key).firstOrNull;
          final secret = entry?.masked ?? false;
          return ValueDiff(
            key: e.key,
            storagePath: view?.ruleFor(e.key)?.storage ?? e.key,
            before: secret ? '••••••' : displayValue(entry?.node, entry?.value),
            after: secret ? secretMask : displayValue(entry?.node, e.value),
            secret: secret,
            afterRaw: e.value,
          );
        }(),
    ], ref);
  }

  // --------------------------------------------------------------- changes

  static String _ticks(String s) => s.replaceAllMapped(RegExp(r'"([^"]+)"'), (m) => '`${m[1]}`');

  static ChangeStatus _status(String? s) => switch (s) {
    'Done' => ChangeStatus.done,
    'Error' => ChangeStatus.error,
    'Undone' => ChangeStatus.undone,
    'Hold' => ChangeStatus.hold,
    'Do' || 'Doing' || 'Undo' || 'Undoing' || 'Abort' => ChangeStatus.doing,
    _ => ChangeStatus.waiting,
  };

  static ChangeStepState _stepState(String? s) => switch (s) {
    'Done' => ChangeStepState.passed,
    'Error' => ChangeStepState.failed,
    'Undone' => ChangeStepState.rolledBack,
    'Doing' || 'Undoing' => ChangeStepState.running,
    _ => ChangeStepState.pending,
  };

  ConfdbChange _change(Map c, List<ConfdbPlug> plugs) {
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    final tasks = (c['tasks'] as List? ?? const []).cast<Map>();
    var done = 0, total = 0;
    final steps = <ChangeStep>[];
    String? custodian, rejectedBy;
    final observers = <String>{};
    for (final t in tasks) {
      final p = t['progress'] as Map? ?? const {};
      done += (p['done'] as int? ?? 0);
      total += (p['total'] as int? ?? 0);
      final summary = t['summary'] as String? ?? t['kind'] as String? ?? '';
      final hook = RegExp(r'hook "?([\w-]+)"? of snap "([^"]+)"').firstMatch(summary);
      final state = _stepState(t['status'] as String?);
      if (hook != null) {
        if (hook[1]!.startsWith('change-view') || hook[1]!.startsWith('save-view')) custodian ??= hook[2];
        if (hook[1]!.startsWith('observe-view')) observers.add(hook[2]!);
        if (state == ChangeStepState.failed) rejectedBy ??= hook[2];
      }
      final start = time(t['spawn-time']), end = time(t['ready-time']);
      final log = (t['log'] as List? ?? const []).cast<String>();
      steps.add(
        ChangeStep(
          title: hook != null ? '`${hook[1]}` on `${hook[2]}`' : _ticks(summary),
          state: state,
          meta: start != null && end != null ? '${end.difference(start).inMilliseconds} ms' : '',
          output: log.isEmpty
              ? null
              : HookOutput(
                  stdout: state == ChangeStepState.failed ? '' : log.join('\n'),
                  stderr: state == ChangeStepState.failed ? log.join('\n') : '',
                ),
        ),
      );
    }
    final summary = _ticks(c['summary'] as String? ?? c['kind'] as String? ?? '');
    final viewPath = RegExp(r'`([\w-]+/[\w-]+/[\w-]+)`').firstMatch(summary)?[1];
    final err = c['err'] as String?;
    return ConfdbChange(
      id: int.tryParse('${c['id']}') ?? 0,
      kind: c['kind'] as String? ?? '',
      summary: summary,
      initiator: (c['kind'] as String? ?? '') == 'auto-connect' ? 'snapd' : 'You',
      initiatorKind: (c['kind'] as String? ?? '') == 'auto-connect' ? InitiatorKind.snap : InitiatorKind.user,
      spawnTime: time(c['spawn-time']) ?? DateTime.now(),
      readyTime: time(c['ready-time']),
      status: _status(c['status'] as String?),
      progressDone: done,
      progressTotal: total,
      view: viewPath == null ? null : ViewRef.parse(viewPath),
      steps: steps,
      custodian: custodian,
      observers: observers.toList(),
      error: err == null ? null : _shortError(err),
      rejectedBy: rejectedBy,
    );
  }

  /// "cannot perform the following tasks:\n- Run hook … (error: x)" → "x"
  static String _shortError(String err) {
    final m = RegExp(r'\(([^()]*)\)\s*$', multiLine: true).firstMatch(err.trim());
    return (m?[1] ?? err).replaceFirst(RegExp(r'^error:\s*'), '').trim();
  }

  // ----------------------------------------------------------------- snaps

  Future<List<ConfdbPlug>> _confdbPlugs() async {
    final r = await _sync('GET', '/v2/connections', query: {'select': 'all', 'interface': 'confdb'}) as Map;
    final established = (r['established'] as List? ?? const []).cast<Map>();
    final plugs = <ConfdbPlug>[];
    for (final p in (r['plugs'] as List? ?? const []).cast<Map>()) {
      final attrs = p['attrs'] as Map? ?? const {};
      final account = attrs['account'] as String?;
      final view = attrs['view'] as String?;
      if (account == null || view == null || !view.contains('/')) continue;
      final snap = p['snap'] as String, plug = p['plug'] as String;
      final conn = established.where((e) => (e['plug'] as Map?)?['snap'] == snap && (e['plug'] as Map?)?['plug'] == plug).firstOrNull;
      plugs.add(
        ConfdbPlug(
          snap: snap,
          plug: plug,
          view: ViewRef.parse('$account/$view'),
          role: attrs['role'] == 'custodian' ? PlugRole.custodian : PlugRole.observer,
          state: conn == null ? ConnState.notConnected : (conn['manual'] == true ? ConnState.connected : ConnState.autoConnected),
        ),
      );
    }
    return plugs;
  }

  @override
  Future<List<SnapInfo>> listSnaps() async {
    final plugs = await _confdbPlugs();
    final names = {for (final p in plugs) p.snap}.toList()..sort();
    if (names.isEmpty) return const [];
    final info = await _sync('GET', '/v2/snaps', query: {'snaps': names.join(',')}) as List? ?? const [];
    final byName = {for (final s in info.cast<Map>()) s['name'] as String: s};
    final hooks = {for (final n in names) n: await _readHooks(n)};
    return [
      for (final n in names)
        () {
          final s = byName[n] ?? const {};
          final rev = '${s['revision'] ?? '?'}';
          final local = rev.startsWith('x');
          final publisher = (s['publisher'] as Map?)?['username'] as String? ?? s['developer'] as String? ?? '?';
          return SnapInfo(
            name: n,
            publisher: publisher,
            revision: rev,
            publisherSigned: !local,
            installNote: local ? 'installed from a local file' : null,
            plugs: plugs.where((p) => p.snap == n).toList(),
            hooks: [for (final h in hooks[n] ?? const <String>[]) DeclaredHook(h)],
            hooksKnown: hooks[n] != null,
          );
        }(),
    ];
  }

  Future<ConfdbChange> _interfaces(String action, ConfdbPlug plug) => _asyncChange('POST', '/v2/interfaces', {
    'action': action,
    'plugs': [
      {'snap': plug.snap, 'plug': plug.plug},
    ],
    'slots': [
      {'snap': action == 'connect' ? 'snapd' : '', 'slot': action == 'connect' ? 'confdb' : ''},
    ],
  });

  @override
  Future<ConfdbChange> connect(ConfdbPlug plug) => _interfaces('connect', plug);

  @override
  Future<ConfdbChange> disconnect(ConfdbPlug plug) => _interfaces('disconnect', plug);

  // --------------------------------------------------------------- signing

  /// Top-level `key: value` headers of an assertion.
  static Map<String, String> assertionHeaders(String text) {
    final headers = <String, String>{};
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) break;
      if (line.startsWith(' ') || !line.contains(':')) continue;
      final i = line.indexOf(':');
      headers[line.substring(0, i)] = line.substring(i + 1).trim();
    }
    return headers;
  }

  Future<void> _ack(String assertion) async {
    final res = await _write('POST', '/v2/assertions', rawBody: assertion, contentType: 'application/x.ubuntu.assertion');
    if (res.isError) throw _error(res, 'assertions');
  }

  /// `snap known [--remote] <type> <key>=<value>…`: the assertion text, or
  /// null if snapd (or, with [remote], the store) doesn't have it.
  Future<String?> _known(String type, Map<String, String> keys, {bool remote = false}) async {
    final r = await Process.run(snapCommand, [
      'known',
      if (remote) '--remote',
      type,
      for (final e in keys.entries) '${e.key}=${e.value}',
    ]).timeout(const Duration(seconds: 60));
    final out = '${r.stdout}';
    return r.exitCode == 0 && out.trim().isNotEmpty ? out : null;
  }

  Future<String?> _fromStore(String type, String key, String value) => _known(type, {key: value}, remote: true);

  /// The account and account-key assertions a signed [assertion] depends on.
  Future<List<String>> _prerequisites(String assertion, SigningKey? key) async {
    final headers = assertionHeaders(assertion);
    final account = headers['authority-id'];
    final sha = headers['sign-key-sha3-384'];
    if (account == null || sha == null || sha.isEmpty) {
      throw const ConfdbException('The signed schema has no signing key in its headers.', command: 'snap sign');
    }
    final accountKey = await _fromStore('account-key', 'public-key-sha3-384', sha);
    final name = key == null ? 'that signed it' : '`${key.name}`';
    if (accountKey == null) {
      throw ConfdbException(
        'The key $name isn’t registered in the Snap Store, so snapd can’t verify the signature. '
        '${key == null ? 'Its owner must register it.' : 'Register it to your account, then sign again.'}',
        command: key == null ? null : 'snapcraft register-key ${key.name}',
      );
    }
    final owner = assertionHeaders(accountKey)['account-id'];
    if (owner != account) {
      throw ConfdbException(
        'The key $name belongs to account `$owner`, but the schema is for account `$account`. '
        'Use a key registered to `$account`, or create the schema under `$owner`.',
      );
    }
    final accountAssertion = await _fromStore('account', 'account-id', account);
    if (accountAssertion == null) {
      throw ConfdbException('The Snap Store has no account `$account`.', command: 'snap known --remote account account-id=$account');
    }
    return [accountAssertion, accountKey];
  }

  @override
  Future<List<SigningKey>> signingKeys() async {
    final r = await Process.run(snapCommand, ['keys', '--json']);
    if (r.exitCode != 0) throw ConfdbException('`snap keys` failed: ${r.stderr}'.trim(), command: 'snap keys');
    final keys = jsonDecode(r.stdout as String) as List? ?? const [];
    return [for (final k in keys.cast<Map>()) SigningKey(name: k['name'] as String, sha3384: k['sha3-384'] as String? ?? '')];
  }

  /// The Store's latest revision of [id], when signed in and it says.
  Future<int?> _storeRevision(SchemaId id) async {
    try {
      return (await store.listSchemas()).where((s) => s.id == id).firstOrNull?.revision;
    } on ConfdbException {
      return null;
    }
  }

  @override
  Future<void> signAndAcknowledge(ConfdbSchema draft, SigningKey key, {bool push = false, void Function(SignPhase phase)? onPhase}) async {
    onPhase?.call(SignPhase.signing);
    final current = (await listSchemas()).where((s) => s.id == draft.id).firstOrNull;
    // Past both the device's and the Store's revision, so the result can be
    // pushed (or installed) either way.
    var revision = [current?.revision ?? 0, await _storeRevision(draft.id) ?? 0].reduce((a, b) => a > b ? a : b) + 1;
    var input = signInput(draft, revision: revision, timestamp: DateTime.now());
    if (push) {
      // The Store's own headers, as its docs prescribe for registering.
      final built = await store.buildAssertion(draft);
      final suggested = int.tryParse('${built['revision'] ?? ''}') ?? 0;
      if (suggested > revision) revision = suggested;
      input = {...built, 'revision': '$revision'};
    }
    final proc = await Process.start(snapCommand, ['sign', '-k', key.name]);
    proc.stdin.write(jsonEncode(input));
    await proc.stdin.close();
    final assertion = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    if (await proc.exitCode != 0) {
      throw ConfdbException('`snap sign` failed: ${err.trim()}', command: 'snap sign -k ${key.name}');
    }
    if (push) {
      onPhase?.call(SignPhase.pushing);
      await store.register(assertion);
    }
    onPhase?.call(SignPhase.acknowledging);
    // snapd only accepts the schema once it knows the signing key, so
    // acknowledge the account and account-key from the store first.
    for (final prerequisite in await _prerequisites(assertion, key)) {
      await _ack(prerequisite);
    }
    await _ack(assertion);
    await _drafts.discard(draft.id);
    _notify();
  }

  // ------------------------------------------------------------ Snap Store

  @override
  Future<StoreSession> storeSession() async {
    try {
      return await store.session();
    } on ConfdbException catch (e) {
      if (e.kind == ConfdbErrorKind.unsupported) return StoreSession.signedOut(detail: e.message);
      rethrow;
    }
  }

  @override
  Future<StoreSession> storeLogin({required String email, required String password, String? otp, StoreEnv env = StoreEnv.production}) =>
      store.login(email: email, password: password, otp: otp, env: env);

  @override
  Future<void> storeLogout() => store.logout();

  @override
  Future<List<ConfdbSchema>> listStoreSchemas() => store.listSchemas();

  @override
  Future<void> installFromStore(SchemaId id) async {
    // The Store's API gives headers and body but no signature; snapd fetches
    // the signed assertion from the store's assertion service instead.
    final keys = {'account-id': id.account, 'name': id.name};
    final assertion = await _known('confdb-schema', keys, remote: true);
    if (assertion == null) {
      throw ConfdbException(
        'snapd couldn’t fetch `${id.path}` from the Snap Store. Open it as a draft and sign it on this device instead.',
        command: 'snap known --remote confdb-schema account-id=${id.account} name=${id.name}',
        kind: ConfdbErrorKind.notFound,
      );
    }
    for (final prerequisite in await _prerequisites(assertion, null)) {
      await _ack(prerequisite);
    }
    await _ack(assertion);
    _notify();
  }

  @override
  Future<void> pushToStore(SchemaId id) async {
    final assertion = await _known('confdb-schema', {'account-id': id.account, 'name': id.name});
    if (assertion == null) {
      throw ConfdbException('No confdb-schema ${id.path} is acknowledged on this device.', kind: ConfdbErrorKind.notFound);
    }
    await store.register(assertion);
    _notify();
  }
}
