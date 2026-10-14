import 'dart:async';
import 'dart:io';

import '../../domain/access.dart';
import '../../domain/analysis.dart';
import '../../domain/schema_codec.dart';
import '../../domain/values.dart';
import '../confdb_repository.dart';
import '../models.dart';
import 'sample_data.dart';

/// Switches for reaching the empty, loading and error states without snapd.
/// Parsed from a comma list, e.g. `slow,no-changes`.
class FakeScenario {
  const FakeScenario({
    this.latency = const Duration(milliseconds: 350),
    this.confdbDisabled = false,
    this.snapdUnreachableOnce = false,
    this.noSchemas = false,
    this.noChanges = false,
    this.loadViewFailsOnce = false,
    this.loggedOut = false,
    this.noKeys = false,
    this.noCustodian = false,
  });

  factory FakeScenario.parse(String spec) {
    final flags = spec.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
    return FakeScenario(
      latency: flags.contains('slow') ? const Duration(seconds: 3) : const Duration(milliseconds: 350),
      confdbDisabled: flags.contains('disabled'),
      snapdUnreachableOnce: flags.contains('unreachable'),
      noSchemas: flags.contains('no-schemas'),
      noChanges: flags.contains('no-changes'),
      loadViewFailsOnce: flags.contains('load-view-fails'),
      loggedOut: flags.contains('logged-out'),
      noKeys: flags.contains('no-keys'),
      noCustodian: flags.contains('no-custodian'),
    );
  }

  final Duration latency;

  /// Start in onboarding: `experimental.confdb` is false.
  final bool confdbDisabled;

  /// The first schema load fails as if snapd didn't answer; Retry succeeds.
  final bool snapdUnreachableOnce;
  final bool noSchemas;
  final bool noChanges;

  /// The first read of an ephemeral value fails in the custodian's load-view hook.
  final bool loadViewFailsOnce;

  /// snapcraft has no credentials.
  final bool loggedOut;

  /// `snap keys` lists nothing.
  final bool noKeys;

  /// telemetry-agent's custodian plug starts disconnected.
  final bool noCustodian;
}

/// In-memory backend seeded with the design's sample data. Writes behave like
/// snapd: they create changes, run (simulated) custodian hooks, and roll back
/// when a hook rejects them.
class FakeConfdbRepository implements ConfdbRepository {
  FakeConfdbRepository({this.scenario = const FakeScenario(), DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _enabled = !scenario.confdbDisabled;
    _unreachable = scenario.snapdUnreachableOnce;
    _loadFails = scenario.loadViewFailsOnce;
    // With confdb disabled there can't be acknowledged schemas or confdb changes yet.
    if (!scenario.noSchemas && !scenario.confdbDisabled) {
      _schemas.addAll([networkRev4, telemetryRev1, systemSnaps]);
      _drafts[networkId] = networkDraft;
    }
    _values.addAll(seedValues());
    _snaps.addAll([
      for (final s in seedSnaps())
        scenario.noCustodian && s.name == 'telemetry-agent'
            ? s.copyWith(plugs: [for (final p in s.plugs) p.copyWith(state: ConnState.notConnected)])
            : s,
    ]);
    if (!scenario.noChanges && !scenario.confdbDisabled) _changes.addAll(seedChanges(_clock()));
  }

  final FakeScenario scenario;
  final DateTime Function() _clock;
  final _events = StreamController<void>.broadcast();
  final _schemas = <ConfdbSchema>[];
  final _drafts = <SchemaId, ConfdbSchema>{};
  final _values = <SchemaId, Map<String, Object?>>{};
  final _snaps = <SnapInfo>[];
  final _changes = <ConfdbChange>[];
  late bool _enabled;
  late bool _unreachable;
  late bool _loadFails;
  var _nextId = 1846;

  @override
  String get backendName => 'Sample data';

  @override
  Stream<void> get onChanged => _events.stream;

  Future<void> _wait([double factor = 1]) =>
      Future<void>.delayed(Duration(milliseconds: (scenario.latency.inMilliseconds * factor).round()));

  void _notify() => _events.add(null);

  ConfdbSchema _schema(SchemaId id) => _schemas.firstWhere(
    (s) => s.id == id,
    orElse: () => throw ConfdbException('No confdb-schema ${id.path} on this device', kind: ConfdbErrorKind.notFound),
  );

  @override
  Future<SystemStatus> systemStatus() async {
    await _wait(0.3);
    return SystemStatus(snapdVersion: '2.77', confdbEnabled: _enabled);
  }

  @override
  Future<void> enableConfdb() async {
    await _wait(3); // stands in for the admin authentication prompt
    _enabled = true;
    _notify();
  }

  @override
  Future<String?> developerAccount() async => 'acme';

  @override
  Future<StoreAccount> storeAccount() async {
    await _wait(0.3);
    if (scenario.loggedOut) return const StoreAccount.loggedOut();
    // Placeholder identity for the sample data.
    return const StoreAccount(login: StoreLogin.loggedIn, username: 'acme', email: 'dev@acme.example', accountId: 'acme');
  }

  @override
  Future<List<ConfdbSchema>> listSchemas() async {
    await _wait();
    if (_unreachable) {
      _unreachable = false;
      throw const ConfdbException(
        'snapd didn’t respond on `/run/snapd.socket`. Check that the snapd service is running, then retry.',
        command: 'systemctl status snapd.service',
        kind: ConfdbErrorKind.unreachable,
      );
    }
    return List.unmodifiable(_schemas);
  }

  @override
  Future<List<ConfdbSchema>> listDrafts() async {
    await _wait(0.3);
    return List.unmodifiable(_drafts.values);
  }

  @override
  Future<void> saveDraft(ConfdbSchema draft) async {
    _drafts[draft.id] = draft.copyWith(isDraft: true);
    _notify();
  }

  @override
  Future<void> discardDraft(SchemaId id) async {
    _drafts.remove(id);
    _notify();
  }

  @override
  Future<ConfdbSchema> importSchema(String filePath) async {
    final parsed = parseSchemaFile(await File(filePath).readAsString());
    final existing = _schemas.where((s) => s.id == parsed.id).firstOrNull;
    final draft = parsed.copyWith(isDraft: true, baseRevision: existing?.revision);
    await saveDraft(draft);
    return draft;
  }

  @override
  Future<ViewSnapshot> readView(ViewRef ref) async {
    await _wait();
    final schema = _schema(ref.schemaId);
    final view = schema.view(ref.view);
    if (view == null) throw ConfdbException('No view ${ref.path}', kind: ConfdbErrorKind.notFound);
    final stored = _values[schema.id] ?? const {};
    final custodian =
        custodianOf(ref, _snaps) ??
        _snaps.expand((s) => s.plugs).where((p) => p.role == PlugRole.custodian && p.view.schemaId == ref.schemaId).firstOrNull;
    HookFailure? failure;
    final entries = <ViewEntry>[];
    for (final rule in view.rules) {
      final node = resolveStoragePath(schema.storage, rule.storage);
      final hint = valueHints[rule.storage];
      if (node != null && node.ephemeral && rule.access.canRead) {
        if (_loadFails) {
          failure = HookFailure(
            snap: custodian?.snap ?? 'custodian',
            hook: 'load-view-${custodian?.plug ?? ref.view}',
            message: 'exited with status 1',
            exitStatus: 1,
            requestPath: rule.request,
          );
          entries.add(ViewEntry(rule: rule, node: node, loadError: '${failure.hook} exited with status 1'));
          continue;
        }
        final v = ephemeralValues[rule.storage];
        entries.add(ViewEntry(rule: rule, node: node, value: v, hasValue: v != null, hint: hint));
        continue;
      }
      final has = stored.containsKey(rule.storage);
      entries.add(
        ViewEntry(
          rule: rule,
          node: node,
          // Write-only values are never read back, and snapd leaves secrets
          // out for non-admins (the app reads as one).
          value: rule.access.canRead && !(node?.secret ?? false) ? stored[rule.storage] : null,
          hasValue: has,
          hint: hint,
        ),
      );
    }
    if (failure != null) _loadFails = false;
    return ViewSnapshot(ref: ref, schema: schema, entries: entries, loadFailure: failure);
  }

  @override
  Future<ConfdbChange> applyValues(ViewRef ref, Map<String, Object?> values) async {
    await _wait(2);
    final schema = _schema(ref.schemaId);
    final view = schema.view(ref.view)!;
    final stored = _values.putIfAbsent(schema.id, () => {});
    final custodian = custodianOf(ref, _snaps);
    final now = _clock();
    final id = _nextId++;

    final diffs = <ValueDiff>[];
    final paths = <String>{};
    String? schemaError;
    for (final e in values.entries) {
      final rule = view.ruleFor(e.key);
      if (rule == null || !rule.access.canWrite) {
        throw ConfdbException('${e.key} is not writable through ${ref.path}', kind: ConfdbErrorKind.permissionDenied);
      }
      final node = resolveStoragePath(schema.storage, rule.storage);
      final secret = !rule.access.canRead || (node?.secret ?? false);
      if (e.value != null && node != null) {
        schemaError ??= validateValue(node, e.value is String ? e.value as String : displayValue(node, e.value, quoteStrings: false));
      }
      paths.add(rule.storage);
      diffs.add(
        ValueDiff(
          key: e.key,
          storagePath: rule.storage,
          before: secret ? '••••••' : displayValue(node, stored[rule.storage], quoteStrings: true),
          after: secret ? secretMask : displayValue(node, e.value, quoteStrings: true),
          secret: secret,
          afterRaw: e.value,
        ),
      );
    }
    // snapd checks the storage schema before creating a change.
    if (schemaError != null) {
      _nextId--;
      throw ConfdbException(
        'Value doesn’t match the storage schema: $schemaError',
        command: snapSetCommand(ref, [for (final e in values.entries) (e.key, e.value, !view.ruleFor(e.key)!.access.canRead)]),
      );
    }

    final hooks = planWriteHooks(schema, _snaps, paths);
    final observers = {
      for (final h in hooks)
        if (h.role == PlugRole.observer) h.snap,
    }.toList();
    final detail = diffs.map((d) => '${d.key} = ${d.secret ? secretMask : d.after.replaceAll('"', '')}').join(', ');
    final n = diffs.length;
    final userStep = ChangeStep(
      title: 'Initiated by user',
      state: ChangeStepState.user,
      meta: '',
      description: 'You, from Confdb Studio · $n ${n == 1 ? 'value' : 'values'} through ${ref.view}',
    );
    final validation = ChangeStep(
      title: 'Validation against storage schema',
      state: ChangeStepState.passed,
      meta: '4 ms',
      description: diffs
          .map((d) => '`${d.storagePath}` is a ${resolveStoragePath(schema.storage, d.storagePath)?.typeLabel ?? 'value'}.')
          .join(' '),
    );

    // net-manager's change-view hook enforces the psk length, like the real custodian.
    String? rejection;
    for (final e in values.entries) {
      final rule = view.ruleFor(e.key)!;
      final hint = valueHints[rule.storage];
      if (hint?.minLength != null && e.value is String && (e.value as String).length < hint!.minLength!) {
        rejection = '${e.key} must be at least ${hint.minLength} characters';
      }
    }

    late ConfdbChange change;
    if (rejection != null && custodian != null) {
      change = ConfdbChange(
        id: id,
        kind: 'set-confdb',
        summary: 'Set confdb through `${ref.path}`',
        detail: detail,
        initiator: 'You',
        initiatorKind: InitiatorKind.user,
        spawnTime: now,
        readyTime: now,
        status: ChangeStatus.error,
        view: ref,
        custodian: custodian.snap,
        observers: observers,
        values: diffs,
        error: rejection,
        rejectedBy: custodian.snap,
        steps: [
          userStep,
          validation,
          ChangeStep(
            title: '`change-view-${custodian.plug}` on `${custodian.snap}`',
            state: ChangeStepState.failed,
            meta: 'exit 1 · 96 ms',
            description: 'The custodian rejected the change.',
            output: HookOutput(stderr: 'error: $rejection'),
          ),
          ChangeStep(
            title: 'Rolled back',
            state: ChangeStepState.rolledBack,
            meta: '',
            description: 'No values were changed. save-view-${custodian.plug} did not run.',
          ),
        ],
      );
    } else {
      for (final d in diffs) {
        if (d.afterRaw == null) {
          stored.remove(d.storagePath);
        } else {
          stored[d.storagePath] = d.afterRaw;
        }
      }
      change = ConfdbChange(
        id: id,
        kind: 'set-confdb',
        summary: 'Set confdb through `${ref.path}`',
        detail: detail,
        initiator: 'You',
        initiatorKind: InitiatorKind.user,
        spawnTime: now,
        readyTime: now,
        status: ChangeStatus.done,
        view: ref,
        custodian: custodian?.snap,
        observers: observers,
        values: diffs,
        steps: [
          userStep,
          validation,
          for (final h in hooks.where((h) => h.role == PlugRole.custodian && h.hook.startsWith('change-view')))
            ChangeStep(
              title: '`${h.hook}` on `${h.snap}`',
              state: ChangeStepState.passed,
              meta: 'exit 0 · 41 ms',
              output: HookOutput(
                stdout: diffs.map((d) => '${d.key}: ${d.secret ? 'updated' : '${d.before} -> ${d.after}'} (accepted)').join('\n'),
              ),
            ),
          for (final h in hooks.where((h) => h.role == PlugRole.custodian && h.hook.startsWith('save-view')))
            ChangeStep(
              title: '`${h.hook}` on `${h.snap}`',
              state: ChangeStepState.passed,
              meta: 'exit 0 · 55 ms',
              description: 'Values persisted.',
            ),
          ChangeStep(
            title: 'Committed',
            state: ChangeStepState.passed,
            meta: '',
            description: diffs.map((d) => '`${d.storagePath}` = ${d.secret ? secretMask : d.after.replaceAll('"', '')}').join(', '),
          ),
          for (final h in hooks.where((h) => h.role == PlugRole.observer))
            ChangeStep(
              title: '`${h.hook}` on `${h.snap}`',
              state: ChangeStepState.passed,
              meta: 'exit 0 · 19 ms',
              description: 'Observer notified after commit.',
            ),
        ],
      );
    }
    _changes.insert(0, change);
    _notify();
    return change;
  }

  @override
  Future<List<ConfdbChange>> listChanges() async {
    await _wait();
    return List.unmodifiable(_changes);
  }

  @override
  Future<ConfdbChange> getChange(int id) async {
    await _wait(0.5);
    return _changes.firstWhere(
      (c) => c.id == id,
      orElse: () => throw ConfdbException('No change with ID $id', command: 'snap change $id', kind: ConfdbErrorKind.notFound),
    );
  }

  @override
  Future<List<SnapInfo>> listSnaps() async {
    await _wait();
    return List.unmodifiable(_snaps);
  }

  Future<ConfdbChange> _setConnection(ConfdbPlug plug, bool connect) async {
    await _wait(2);
    final i = _snaps.indexWhere((s) => s.name == plug.snap);
    final snap = _snaps[i];
    _snaps[i] = snap.copyWith(
      plugs: [
        for (final p in snap.plugs)
          if (p.plug == plug.plug) p.copyWith(state: connect ? ConnState.connected : ConnState.notConnected) else p,
      ],
    );
    final now = _clock();
    final verb = connect ? 'Connect' : 'Disconnect';
    final change = ConfdbChange(
      id: _nextId++,
      kind: connect ? 'connect-snap' : 'disconnect-snap',
      summary: '$verb `${plug.id}`',
      initiator: 'You',
      initiatorKind: InitiatorKind.user,
      spawnTime: now,
      readyTime: now,
      status: ChangeStatus.done,
      steps: [
        const ChangeStep(title: 'Initiated by user', state: ChangeStepState.user, meta: '', description: 'You, from Confdb Studio'),
        ChangeStep(
          title: '$verb `${plug.id}` ${connect ? 'to' : 'from'} `${plug.view.path}`',
          state: ChangeStepState.passed,
          meta: '11 ms',
        ),
      ],
    );
    _changes.insert(0, change);
    _notify();
    return change;
  }

  @override
  Future<ConfdbChange> connect(ConfdbPlug plug) => _setConnection(plug, true);

  @override
  Future<ConfdbChange> disconnect(ConfdbPlug plug) => _setConnection(plug, false);

  @override
  Future<List<SigningKey>> signingKeys() async {
    await _wait(0.5);
    return scenario.noKeys ? const [] : signingKeysSeed;
  }

  @override
  Future<ConfdbChange?> signAndAcknowledge(ConfdbSchema draft, SigningKey key, {void Function(SignPhase phase)? onPhase}) async {
    onPhase?.call(SignPhase.signing);
    await _wait(3);
    onPhase?.call(SignPhase.acknowledging);
    await _wait(3);
    final existing = _schemas.indexWhere((s) => s.id == draft.id);
    final revision = (existing < 0 ? 0 : _schemas[existing].revision ?? 0) + 1;
    final signed = ConfdbSchema(
      id: draft.id,
      revision: revision,
      summary: draft.summary,
      signedBy: draft.id.account,
      views: draft.views,
      storage: draft.storage,
    );
    if (existing < 0) {
      _schemas.insert(0, signed);
    } else {
      _schemas[existing] = signed;
    }
    _values.putIfAbsent(draft.id, () => {});
    _drafts.remove(draft.id);
    final now = _clock();
    final change = ConfdbChange(
      id: _nextId++,
      kind: 'ack-schema',
      summary: 'Acknowledge `${draft.id.path}` rev $revision',
      detail: 'signed with ${key.name}',
      initiator: 'You',
      initiatorKind: InitiatorKind.user,
      spawnTime: now,
      readyTime: now,
      status: ChangeStatus.done,
      steps: [
        const ChangeStep(title: 'Initiated by user', state: ChangeStepState.user, meta: '', description: 'You, from Confdb Studio'),
        ChangeStep(
          title: 'Sign with `${key.name}`',
          state: ChangeStepState.passed,
          meta: '310 ms',
          description: 'SHA3-384 ${key.shortFingerprint}',
        ),
        ChangeStep(title: 'Check signature of `${draft.id.path}` rev $revision', state: ChangeStepState.passed, meta: '6 ms'),
        ChangeStep(title: 'Acknowledged', state: ChangeStepState.passed, meta: '', description: 'Revision $revision is now in use.'),
      ],
    );
    _changes.insert(0, change);
    _notify();
    return change;
  }
}
