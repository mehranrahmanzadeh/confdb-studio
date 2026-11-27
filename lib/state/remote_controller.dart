import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/remote/message_service.dart';
import '../data/remote/remote_models.dart';
import '../domain/remote.dart';

/// The Remote tab: devices, the requests sent to them through the Store's
/// message service, and their answers.
///
/// Requests are sent in named sessions, kept across runs (removing one
/// drops the requests devices haven't collected yet); the service only
/// knows their IDs, so the names are kept here. Each session queues the
/// answers to its own requests. While any request is waiting for an
/// answer, its session is polled — every few seconds at first, backing off
/// to every 30 seconds. Each response is saved before it's acknowledged,
/// and answers seen twice are recorded once.
class RemoteController extends ChangeNotifier {
  RemoteController({
    required this.connect,
    required this.signer,
    required this.storage,
    this.defaults = const RemoteSettings(),
    DateTime Function()? clock,
    this.pollDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : _clock = clock ?? DateTime.now;

  /// The name of the session opened when a message is sent with none.
  static const defaultSessionName = 'Default session';

  /// Builds the client for the settings in use.
  final MessageService Function(RemoteSettings settings) connect;
  final RequestSigner signer;
  final RemoteStorage storage;

  /// Settings before any are saved.
  final RemoteSettings defaults;

  /// Waits between polls; the last repeats.
  final List<Duration> pollDelays;
  final DateTime Function() _clock;

  RemoteState _state = const RemoteState();
  MessageService? _service;
  bool _loaded = false;
  bool _polling = false;
  bool _disposed = false;
  int _pollStep = 0;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Object? _pollError;
  String? _pollErrorSession;
  DateTime? _lastPoll;
  Future<void>? _loading;
  Future<RemoteSession>? _creatingDefault;
  final _opening = <String, Future<String>>{};

  bool get loaded => _loaded;
  RemoteSettings get settings => _state.settings;
  List<RemoteDevice> get devices => _state.devices;

  /// The sessions on the service in [settings], oldest first.
  List<RemoteSession> get sessions => [
    for (final s in _state.sessions)
      if (s.service == settings.serviceKey) s,
  ];

  /// The selected session, or the first when none is.
  RemoteSession? get currentSession => sessions.where((s) => s.key == _state.current).firstOrNull ?? sessions.firstOrNull;

  RemoteSession? session(String key) => _state.sessions.where((s) => s.key == key).firstOrNull;

  /// The current session's requests, newest first.
  List<RemoteRequest> get requests {
    final key = currentSession?.key;
    if (key == null) return const [];
    return [
      for (final r in _state.requests)
        if (r.session == key) r,
    ];
  }

  /// Requests in every session on this service, newest first.
  List<RemoteRequest> get allRequests {
    final keys = {for (final s in sessions) s.key};
    return [
      for (final r in _state.requests)
        if (keys.contains(r.session)) r,
    ];
  }

  /// Why the last poll failed, until one succeeds.
  Object? get pollError => _pollError;

  /// The name of the session the last poll failed for.
  String? get pollErrorSession => _pollErrorSession;
  DateTime? get lastPoll => _lastPoll;
  bool get polling => _polling;
  DateTime get now => _clock();

  /// Requests in any session still waiting for an answer from some device.
  int get waitingCount => allRequests.where((r) => r.isWaitingAt(now)).length;

  /// Requests in [key] still waiting for an answer.
  int waitingIn(String key) => _state.requests.where((r) => r.session == key && r.isWaitingAt(now)).length;

  RemoteDevice? device(String id) => devices.where((d) => d.id.id == id).firstOrNull;

  RemoteRequest? request(String messageId) => _state.requests.where((r) => r.messageId == messageId).firstOrNull;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final saved = await storage.load();
    _state = saved ?? RemoteState(settings: defaults);
    _loaded = true;
    _notify();
    _schedule();
    _refreshQuietly();
  }

  /// Fills in the account when none is set, e.g. from the Store login.
  Future<void> suggestAccount(String account) async {
    await load();
    if (settings.account.isEmpty && account.isNotEmpty) await updateSettings(settings.copyWith(account: account));
  }

  /// Sessions are kept per service, so switching back to one shows its
  /// sessions again.
  Future<void> updateSettings(RemoteSettings next) async {
    await load();
    final sameService = next.sameService(settings);
    _state = _state.copyWith(settings: next, current: sameService ? _state.current : null);
    _service = null;
    _pollError = null;
    _pollErrorSession = null;
    await _save();
    _schedule();
    if (!sameService) _refreshQuietly();
  }

  /// Shows [key]'s requests, and checks it for answers.
  Future<void> selectSession(String key) async {
    _state = _state.copyWith(current: key);
    await _save();
    _pollStep = 0;
    _schedule();
    if (session(key)?.id != null) unawaited(_poll());
  }

  /// Opens a session on the service and selects it.
  Future<RemoteSession> createSession(String name) async {
    await load();
    _requireConnection();
    final id = await _api.createSession();
    final s = RemoteSession(key: id, id: id, service: settings.serviceKey, name: name.trim(), created: now);
    _state = _state.copyWith(sessions: [..._state.sessions.where((e) => e.key != id), s], current: s.key);
    await _save();
    return s;
  }

  /// Names are only kept by Studio; the service doesn't know them.
  Future<void> renameSession(String key, String name) async {
    _updateSession(key, (s) => s.copyWith(name: name.trim()));
    await _save();
  }

  /// Removes [key] from the service, with its requests and answers.
  /// Requests devices haven't collected yet are dropped by the service, and
  /// answers still on their way are lost.
  Future<void> removeSession(String key) async {
    final s = session(key);
    if (s == null) return;
    final id = s.id;
    if (id != null) {
      try {
        await _api.removeSession(id);
      } on MessageServiceException catch (e) {
        if (!e.sessionGone) rethrow;
      }
    }
    _state = _state.copyWith(
      sessions: [..._state.sessions.where((e) => e.key != key)],
      requests: [..._state.requests.where((r) => r.session != key)],
      current: _state.current == key ? null : _state.current,
    );
    if (_pollErrorSession == s.displayName) {
      _pollError = null;
      _pollErrorSession = null;
    }
    await _save();
    _schedule();
  }

  /// Matches the sessions with the service's: sessions opened elsewhere are
  /// added unnamed, and ones the service no longer has are marked gone.
  Future<void> refreshSessions() async {
    await load();
    _requireConnection();
    final service = settings.serviceKey;
    final ids = await _api.listSessions();
    final known = {
      for (final s in _state.sessions)
        if (s.service == service && s.id != null) s.id,
    };
    _state = _state.copyWith(
      sessions: [
        for (final s in _state.sessions)
          if (s.service == service && s.id != null && !ids.contains(s.id)) s.copyWith(id: null, ackToken: null) else s,
        for (final id in ids)
          if (!known.contains(id)) RemoteSession(key: id, id: id, service: service),
      ],
    );
    await _save();
    _schedule();
  }

  void _refreshQuietly() {
    if (!settings.canConnect) return;
    unawaited(
      refreshSessions().catchError((Object _) {
        // Shown when a request is sent or the list is refreshed by hand.
      }, test: (e) => e is ConfdbException),
    );
  }

  void _requireConnection() {
    if (!settings.canConnect) throw const ConfdbException('Finish the Remote settings first');
  }

  Future<void> addDevice(RemoteDevice d) async {
    await load();
    _state = _state.copyWith(devices: [...devices.where((e) => e.id != d.id), d]);
    await _save();
  }

  Future<void> removeDevice(DeviceId id) async {
    _state = _state.copyWith(devices: [...devices.where((e) => e.id != id)]);
    await _save();
  }

  Future<void> deleteRequest(String messageId) async {
    _state = _state.copyWith(requests: [..._state.requests.where((r) => r.messageId != messageId)]);
    await _save();
  }

  /// Drops every request in the current session no device is still
  /// expected to answer.
  Future<void> clearFinished() async {
    final key = currentSession?.key;
    _state = _state.copyWith(
      requests: [..._state.requests.where((r) => r.session != key || r.isWaitingAt(now) || !r.sent && r.sendError == null)],
    );
    await _save();
  }

  /// Signs a request for [devices] and sends it in the current session,
  /// opening a [defaultSessionName] session when there's none. A failure to
  /// sign or to open that session is thrown; a failure to send is recorded
  /// on the returned request.
  Future<RemoteRequest> send({
    required RemoteAction action,
    required ViewRef view,
    required List<DeviceId> devices,
    List<String> keys = const [],
    Map<String, Object?> values = const {},
  }) async {
    await load();
    final s = settings;
    if (!s.isComplete) throw const ConfdbException('Finish the Remote settings first');
    final target =
        currentSession ?? await (_creatingDefault ??= createSession(defaultSessionName).whenComplete(() => _creatingDefault = null));
    final body = confdbMessageBody(action: action, view: view, keys: keys, values: values);
    final created = now;
    RemoteRequest build(String id, String assertion) => RemoteRequest(
      messageId: id,
      session: target.key,
      action: action,
      view: view.path,
      devices: [for (final d in devices) d.id],
      created: created,
      validUntil: created.add(s.validity),
      keys: keys,
      values: values,
      assertion: assertion,
    );
    var id = newMessageId();
    var req = build(id, await _sign(s, id, devices, body, created));
    _put(req);
    await _save();
    try {
      try {
        await _exchangeIn(target.key, (session) => _api.exchange(session, send: [req.assertion!]));
      } on MessageServiceException catch (e) {
        if (!e.duplicateId) rethrow;
        // Someone used the ID before; sign again under a new one.
        final old = id;
        id = newMessageId();
        req = build(id, await _sign(s, id, devices, body, created));
        _state = _state.copyWith(requests: [..._state.requests.where((r) => r.messageId != old)]);
        _put(req);
        await _exchangeIn(target.key, (session) => _api.exchange(session, send: [req.assertion!]));
      }
      req = req.copyWith(sent: true);
    } on ConfdbException catch (e) {
      req = req.copyWith(sendError: e.message);
    }
    _put(req);
    await _save();
    _pollStep = 0;
    _schedule();
    return req;
  }

  /// Sends [r] again to the devices that didn't succeed, as a new request.
  Future<RemoteRequest> retryFailed(RemoteRequest r) {
    final failed = [
      for (final d in r.devices)
        if (r.stateOf(d, now).isFailure) DeviceId.parse(d),
    ];
    return send(action: r.action, view: ViewRef.parse(r.view), devices: failed, keys: r.keys, values: r.values);
  }

  /// Polls now, and restarts the backoff.
  Future<void> pollNow() {
    _pollStep = 0;
    return _poll();
  }

  Future<String> _sign(RemoteSettings s, String id, List<DeviceId> devices, Map<String, Object?> body, DateTime created) => signer.sign(
    requestMessageHeaders(account: s.account, messageId: id, devices: devices, body: body, now: created, validFor: s.validity),
    s.signingKey,
  );

  MessageService get _api => _service ??= connect(settings);

  /// Runs [op] in session [key], opening it again on the service when it's
  /// gone.
  Future<T> _exchangeIn<T>(String key, Future<T> Function(String id) op) async {
    var id = session(key)?.id ?? await _reopen(key);
    try {
      return await op(id);
    } on MessageServiceException catch (e) {
      if (!e.sessionGone) rethrow;
      id = await _reopen(key);
      return op(id);
    }
  }

  /// Concurrent sends share one new session.
  Future<String> _reopen(String key) => _opening[key] ??= _openOnService(key).whenComplete(() {
    _opening.remove(key);
  });

  Future<String> _openOnService(String key) async {
    final id = await _api.createSession();
    _updateSession(key, (s) => s.copyWith(id: id, ackToken: null));
    await _save();
    return id;
  }

  Future<void> _poll() async {
    if (_polling || !_loaded) return;
    final t = now;
    final current = currentSession?.key;
    final targets = [
      for (final s in sessions)
        if (s.id != null && (s.key == current || _hasWaiting(s.key, t))) s.key,
    ];
    if (targets.isEmpty) return;
    _polling = true;
    _pollTimer?.cancel();
    _notify();
    var gotAnswers = false;
    Object? error;
    String? errorSession;
    try {
      for (final key in targets) {
        try {
          gotAnswers |= await _pollSession(key);
        } on ConfdbException catch (e) {
          error = e;
          errorSession = session(key)?.displayName;
        }
      }
      await _save();
    } finally {
      _pollError = error;
      _pollErrorSession = errorSession;
      _polling = false;
      _lastPoll = now;
      if (gotAnswers) _pollStep = 0;
      _pollStep++;
      _notify();
      _schedule();
    }
  }

  /// Fetches, files and acknowledges [key]'s answers; true when any was new.
  Future<bool> _pollSession(String key) async {
    final id = session(key)?.id;
    if (id == null) return false;
    var gotAnswers = false;
    try {
      var after = session(key)?.ackToken;
      for (var i = 0; i < 20; i++) {
        final res = await _api.exchange(id, limit: 50, after: after);
        if (after != null) _updateSession(key, (s) => s.copyWith(ackToken: null));
        if (res.messages.isEmpty) break;
        gotAnswers |= _record(res.messages);
        after = res.messages.last.token;
        // Saved before acknowledging, so an answer isn't lost if Studio stops.
        _updateSession(key, (s) => s.copyWith(ackToken: after));
        await _save();
        if (!res.hasMore) {
          await _api.exchange(id, after: after);
          _updateSession(key, (s) => s.copyWith(ackToken: null));
          break;
        }
      }
    } on MessageServiceException catch (e) {
      // Requests devices hadn't collected are gone with it.
      if (e.sessionGone && session(key)?.id == id) {
        _updateSession(key, (s) => s.copyWith(id: null, ackToken: null));
        await _save();
      }
      rethrow;
    }
    return gotAnswers;
  }

  bool _hasWaiting(String key, DateTime t) => _state.requests.any((r) => r.session == key && r.isWaitingAt(t));

  /// Files [messages] under their requests; true when any was new.
  bool _record(List<QueuedMessage> messages) {
    var changed = false;
    for (final m in messages) {
      final RemoteResponse r;
      try {
        r = RemoteResponse.fromAssertion(m.data);
      } on FormatException {
        continue;
      }
      final base = r.messageId.replaceFirst(RegExp(r'-\d+$'), '');
      final req = request(base);
      if (req == null || !req.devices.contains(r.device) || req.responses.containsKey(r.device)) continue;
      _put(req.copyWith(responses: {...req.responses, r.device: r}));
      changed = true;
    }
    return changed;
  }

  void _schedule() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    if (_disposed || !_loaded) return;
    final t = now;
    final open = {
      for (final s in sessions)
        if (s.id != null) s.key,
    };
    final waiting = allRequests.where((r) => r.isWaitingAt(t)).toList();
    if (waiting.isEmpty) return;
    if (waiting.any((r) => open.contains(r.session))) {
      final delay = pollDelays[_pollStep.clamp(0, pollDelays.length - 1)];
      _pollTimer = Timer(delay, _poll);
    }
    // Repaint when the next request expires.
    final next = waiting.map((r) => r.validUntil).reduce((a, b) => a.isBefore(b) ? a : b);
    _expiryTimer = Timer(next.difference(t) + const Duration(milliseconds: 50), () {
      _notify();
      _schedule();
    });
  }

  void _put(RemoteRequest r) {
    final all = _state.requests;
    final i = all.indexWhere((e) => e.messageId == r.messageId);
    _state = _state.copyWith(requests: i < 0 ? [r, ...all] : ([...all]..[i] = r));
    _notify();
  }

  void _updateSession(String key, RemoteSession Function(RemoteSession) update) {
    _state = _state.copyWith(sessions: [for (final s in _state.sessions) s.key == key ? update(s) : s]);
  }

  Future<void> _save() async {
    _notify();
    await storage.save(_state);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}
