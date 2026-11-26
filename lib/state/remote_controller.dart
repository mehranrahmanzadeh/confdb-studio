import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/remote/message_service.dart';
import '../data/remote/remote_models.dart';
import '../domain/remote.dart';

/// The Remote tab: devices, the requests sent to them through the Store's
/// message service, and their answers.
///
/// Requests are sent in one session that's kept across runs (removing it
/// would drop requests devices haven't collected yet). While any request is
/// waiting for an answer, the session is polled — every few seconds at
/// first, backing off to every 30 seconds. Each response is saved before
/// it's acknowledged, and answers seen twice are recorded once.
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
  DateTime? _lastPoll;
  Future<void>? _loading;
  Future<String>? _opening;

  bool get loaded => _loaded;
  RemoteSettings get settings => _state.settings;
  List<RemoteDevice> get devices => _state.devices;

  /// Newest first.
  List<RemoteRequest> get requests => _state.requests;
  String? get session => _state.session;

  /// Why the last poll failed, until one succeeds.
  Object? get pollError => _pollError;
  DateTime? get lastPoll => _lastPoll;
  bool get polling => _polling;
  DateTime get now => _clock();

  /// Requests still waiting for an answer from some device.
  int get waitingCount => requests.where((r) => r.isWaitingAt(now)).length;

  RemoteDevice? device(String id) => devices.where((d) => d.id.id == id).firstOrNull;

  RemoteRequest? request(String messageId) => requests.where((r) => r.messageId == messageId).firstOrNull;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final saved = await storage.load();
    _state = saved ?? RemoteState(settings: defaults);
    _loaded = true;
    _notify();
    _schedule();
  }

  /// Fills in the account when none is set, e.g. from the Store login.
  Future<void> suggestAccount(String account) async {
    await load();
    if (settings.account.isEmpty && account.isNotEmpty) await updateSettings(settings.copyWith(account: account));
  }

  Future<void> updateSettings(RemoteSettings next) async {
    await load();
    final sameService = next.sameService(settings);
    _state = RemoteState(
      settings: next,
      devices: devices,
      requests: requests,
      session: sameService ? session : null,
      ackToken: sameService ? _state.ackToken : null,
    );
    _service = null;
    _pollError = null;
    await _save();
    _schedule();
  }

  Future<void> addDevice(RemoteDevice d) async {
    await load();
    _state = _with(devices: [...devices.where((e) => e.id != d.id), d]);
    await _save();
  }

  Future<void> removeDevice(DeviceId id) async {
    _state = _with(devices: [...devices.where((e) => e.id != id)]);
    await _save();
  }

  Future<void> deleteRequest(String messageId) async {
    _state = _with(requests: [...requests.where((r) => r.messageId != messageId)]);
    await _save();
  }

  /// Drops every request no device is still expected to answer.
  Future<void> clearFinished() async {
    _state = _with(requests: [...requests.where((r) => r.isWaitingAt(now) || !r.sent && r.sendError == null)]);
    await _save();
  }

  /// Signs a request for [devices] and sends it. A failure to sign is thrown;
  /// a failure to send is recorded on the returned request.
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
    final body = confdbMessageBody(action: action, view: view, keys: keys, values: values);
    final created = now;
    var id = newMessageId();
    var assertion = await _sign(s, id, devices, body, created);
    var req = RemoteRequest(
      messageId: id,
      action: action,
      view: view.path,
      devices: [for (final d in devices) d.id],
      created: created,
      validUntil: created.add(s.validity),
      keys: keys,
      values: values,
      assertion: assertion,
    );
    _put(req);
    await _save();
    try {
      try {
        await _exchangeWithSession((session) => _api.exchange(session, send: [assertion]));
      } on MessageServiceException catch (e) {
        if (!e.duplicateId) rethrow;
        // Someone used the ID before; sign again under a new one.
        final old = id;
        id = newMessageId();
        assertion = await _sign(s, id, devices, body, created);
        req = RemoteRequest(
          messageId: id,
          action: action,
          view: view.path,
          devices: req.devices,
          created: created,
          validUntil: req.validUntil,
          keys: keys,
          values: values,
          assertion: assertion,
        );
        _state = _with(requests: [...requests.where((r) => r.messageId != old)]);
        _put(req);
        await _exchangeWithSession((session) => _api.exchange(session, send: [assertion]));
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

  /// Removes the session and starts afresh. Requests devices haven't
  /// collected yet are dropped by the service, and answers still on their
  /// way are lost.
  Future<void> resetSession() async {
    final old = session;
    _state = RemoteState(settings: settings, devices: devices, requests: requests);
    await _save();
    if (old == null) return;
    try {
      await _api.removeSession(old);
    } on ConfdbException {
      // It may be gone already; nothing else refers to it.
    }
  }

  Future<String> _sign(RemoteSettings s, String id, List<DeviceId> devices, Map<String, Object?> body, DateTime created) => signer.sign(
    requestMessageHeaders(account: s.account, messageId: id, devices: devices, body: body, now: created, validFor: s.validity),
    s.signingKey,
  );

  MessageService get _api => _service ??= connect(settings);

  /// Runs [op] in the session, opening one when there's none or it's gone.
  Future<T> _exchangeWithSession<T>(Future<T> Function(String session) op) async {
    var s = session ?? await _openSession();
    try {
      return await op(s);
    } on MessageServiceException catch (e) {
      if (!e.sessionGone) rethrow;
      s = await _openSession();
      return op(s);
    }
  }

  /// Concurrent sends share one new session.
  Future<String> _openSession() => _opening ??= _createSession().whenComplete(() => _opening = null);

  Future<String> _createSession() async {
    final s = await _api.createSession();
    _state = RemoteState(settings: settings, devices: devices, requests: requests, session: s);
    await _save();
    return s;
  }

  Future<void> _poll() async {
    final s = session;
    if (_polling || s == null || !_loaded) return;
    _polling = true;
    _pollTimer?.cancel();
    _notify();
    var gotAnswers = false;
    try {
      var after = _state.ackToken;
      for (var i = 0; i < 20; i++) {
        final res = await _api.exchange(s, limit: 50, after: after);
        if (after != null) _state = _with(ackToken: null);
        if (res.messages.isEmpty) break;
        gotAnswers |= _record(res.messages);
        // Saved before acknowledging, so an answer isn't lost if Studio stops.
        _state = _with(ackToken: res.messages.last.token);
        await _save();
        after = _state.ackToken;
        if (!res.hasMore) {
          await _api.exchange(s, after: after);
          _state = _with(ackToken: null);
          break;
        }
      }
      await _save();
      _pollError = null;
    } on MessageServiceException catch (e) {
      _pollError = e;
      if (e.sessionGone) {
        // Requests devices hadn't collected are gone with it.
        _state = RemoteState(settings: settings, devices: devices, requests: requests);
        await _save();
      }
    } on ConfdbException catch (e) {
      _pollError = e;
    } finally {
      _polling = false;
      _lastPoll = now;
      if (gotAnswers) _pollStep = 0;
      _pollStep++;
      _notify();
      _schedule();
    }
  }

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
    final waiting = requests.where((r) => r.isWaitingAt(t)).toList();
    if (waiting.isEmpty || session == null) return;
    final delay = pollDelays[_pollStep.clamp(0, pollDelays.length - 1)];
    _pollTimer = Timer(delay, _poll);
    // Repaint when the next request expires.
    final next = waiting.map((r) => r.validUntil).reduce((a, b) => a.isBefore(b) ? a : b);
    _expiryTimer = Timer(next.difference(t) + const Duration(milliseconds: 50), () {
      _notify();
      _schedule();
    });
  }

  void _put(RemoteRequest r) {
    final i = requests.indexWhere((e) => e.messageId == r.messageId);
    _state = _with(requests: i < 0 ? [r, ...requests] : ([...requests]..[i] = r));
    _notify();
  }

  RemoteState _with({List<RemoteDevice>? devices, List<RemoteRequest>? requests, Object? ackToken = _keep}) => RemoteState(
    settings: settings,
    devices: devices ?? this.devices,
    requests: requests ?? this.requests,
    session: session,
    ackToken: identical(ackToken, _keep) ? _state.ackToken : ackToken as String?,
  );

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

const _keep = Object();
