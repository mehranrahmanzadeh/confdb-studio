// Sample backend for the Remote tab: a message service whose devices answer
// requests a few seconds after they're sent, as real ones do when they next
// poll.
import 'dart:convert';

import '../../domain/remote.dart';
import '../fake/sample_data.dart';
import 'message_service.dart';
import 'remote_models.dart';

/// How a sample device behaves.
enum FakeDeviceMode {
  /// Answers every request.
  online,

  /// Never polls, so its requests expire.
  offline,

  /// Has no confdb-control delegation for the sender.
  undelegated,
}

class FakeDevice {
  FakeDevice(this.id, {this.mode = FakeDeviceMode.online, Map<String, Map<String, Object?>>? values}) : values = values ?? {};

  final DeviceId id;
  final FakeDeviceMode mode;

  /// `<account>/<schema>` → its data, by request path.
  final Map<String, Map<String, Object?>> values;
}

final _gw1 = DeviceId('GW-0001', 'gateway-pro', acmeAccountId);
final _gw2 = DeviceId('GW-0002', 'gateway-pro', acmeAccountId);
final _hub = DeviceId('SH-0107', 'sensor-hub', acmeAccountId);
final _core = DeviceId('a1b2c3d4', 'ubuntu-core-24-amd64', 'canonical');

Map<String, Map<String, Object?>> _network(String ssid) => {
  '$acmeAccountId/network': {
    'ssid': ssid,
    'psk': 'correct-horse-battery',
    'band': '5GHz',
    'status': 'connected',
    'http': 'http://proxy.acme.internal:3128',
    'no-proxy': ['localhost', '.acme.internal'],
  },
  '$acmeAccountId/telemetry': {'enabled': true, 'interval': 3600},
};

/// The devices the sample service knows.
List<FakeDevice> sampleRemoteDevices() => [
  FakeDevice(_gw1, values: _network('acme-lobby')),
  FakeDevice(_gw2, values: _network('acme-warehouse')),
  FakeDevice(_hub, mode: FakeDeviceMode.offline),
  FakeDevice(_core, mode: FakeDeviceMode.undelegated),
];

/// The sample Remote tab: configured, with the sample devices added.
RemoteState sampleRemoteState() => RemoteState(
  settings: const RemoteSettings(
    storeUrl: 'https://api.snapcraft.example',
    account: acmeAccountId,
    token: 'sample-token',
    signingKey: 'acme-release',
  ),
  devices: [
    RemoteDevice(_gw1, label: 'Lobby gateway'),
    RemoteDevice(_gw2, label: 'Warehouse gateway'),
    RemoteDevice(_hub),
    RemoteDevice(_core, label: 'Lab NUC'),
  ],
);

/// Signs with a made-up signature.
class FakeRequestSigner implements RequestSigner {
  @override
  Future<String> sign(Map<String, Object?> headers, String key) async => _serialize({...headers, 'sign-key-sha3-384': 'fake-$key'});
}

String _serialize(Map<String, Object?> headers) {
  final body = headers['body'] as String? ?? '';
  final b = StringBuffer();
  for (final e in headers.entries) {
    if (e.key == 'body') continue;
    if (e.value is List) {
      b.writeln('${e.key}:');
      for (final v in e.value! as List) {
        b.writeln('  - $v');
      }
    } else {
      b.writeln('${e.key}: ${e.value}');
    }
  }
  if (body.isNotEmpty) b.writeln('body-length: ${utf8.encode(body).length}');
  b.write('\n');
  if (body.isNotEmpty) b.write('$body\n\n');
  b.write('AXNpZw==');
  return b.toString();
}

class _Pending {
  _Pending(this.session, this.request, this.due);
  final String session;
  final ParsedAssertion request;
  final DateTime due;
}

class FakeMessageService implements MessageService {
  FakeMessageService({List<FakeDevice>? devices, this.answerDelay = const Duration(seconds: 4), DateTime Function()? clock})
    : devices = {for (final d in devices ?? sampleRemoteDevices()) d.id.id: d},
      _clock = clock ?? DateTime.now;

  final Map<String, FakeDevice> devices;

  /// How long after sending a device's answer turns up.
  final Duration answerDelay;
  final DateTime Function() _clock;

  final _sessions = <String, List<QueuedMessage>>{};
  final _pending = <_Pending>[];
  final _usedIds = <String>{};
  var _next = 0;

  /// Request-messages received, oldest first.
  final received = <String>[];

  @override
  Future<List<String>> listSessions() async => [..._sessions.keys];

  @override
  Future<String> createSession() async {
    final id = 'FAKESESSION${_next++}';
    _sessions[id] = [];
    return id;
  }

  @override
  Future<void> removeSession(String session) async {
    _sessions.remove(session);
    _pending.removeWhere((p) => p.session == session);
  }

  @override
  Future<ExchangeResult> exchange(String session, {int limit = 0, String? after, List<String> send = const []}) async {
    final queue = _sessions[session];
    if (queue == null) throw const MessageServiceException('session not found', status: 404);
    final parsed = [for (final m in send) parseAssertion(m)];
    for (final (i, a) in parsed.indexed) {
      if (a.header('type') != 'request-message') {
        throw MessageServiceException('message $i: cannot use assertion: not a request-message', status: 400);
      }
      if (_usedIds.contains(a.header('message-id'))) {
        throw MessageServiceException('message $i: ${a.header('message-id')}: duplicate message id', status: 409);
      }
    }
    final now = _clock();
    for (final a in parsed) {
      _usedIds.add(a.header('message-id')!);
      received.add(send[parsed.indexOf(a)]);
      _pending.add(_Pending(session, a, now.add(answerDelay)));
    }
    if (after != null) {
      final i = queue.indexWhere((m) => m.token == after);
      if (i >= 0) queue.removeRange(0, i + 1);
    }
    for (final p in [..._pending]) {
      if (p.due.isAfter(now)) continue;
      _pending.remove(p);
      for (final d in p.request.headers['devices'] as List<String>? ?? const <String>[]) {
        final answer = _answer(p.request, devices[d], now);
        if (answer != null) _sessions[p.session]?.add(QueuedMessage(data: answer, token: 'tok${_next++}'));
      }
    }
    return ExchangeResult(messages: queue.take(limit).toList(), hasMore: queue.length > limit);
  }

  String? _answer(ParsedAssertion req, FakeDevice? device, DateTime now) {
    if (device == null || device.mode == FakeDeviceMode.offline) return null;
    final (status, body) = switch (device.mode) {
      FakeDeviceMode.undelegated => (MessageStatus.unauthorized, {'message': 'cannot access view: no delegation for operator'}),
      _ => _apply(req, device),
    };
    return _serialize({
      'type': 'response-message',
      'authority-id': device.id.brand,
      'account-id': req.header('account-id'),
      'message-id': req.header('message-id'),
      'device': device.id.id,
      'status': status.name,
      'timestamp': rfc3339(now),
      'body': jsonEncode(body),
    });
  }

  (MessageStatus, Map<String, Object?>) _apply(ParsedAssertion req, FakeDevice device) {
    final Map body;
    try {
      body = jsonDecode(req.body) as Map;
    } on Object {
      return (MessageStatus.rejected, {'message': 'cannot decode request body'});
    }
    final view = '${body['view']}';
    final schema = '${body['account']}/${view.split('/').first}';
    final data = device.values[schema];
    if (data == null) return (MessageStatus.error, {'message': 'cannot find confdb schema $schema'});
    if (body['action'] == 'set') {
      if (view.endsWith('-state')) {
        return (MessageStatus.error, {'message': 'cannot set through ${body['account']}/$view: view is read-only'});
      }
      final values = (body['values'] as Map? ?? const {}).cast<String, Object?>();
      for (final e in values.entries) {
        if (e.value == null) {
          data.remove(e.key);
        } else {
          data[e.key] = e.value;
        }
      }
      return (MessageStatus.success, {});
    }
    final keys = [for (final k in body['keys'] as List? ?? const []) '$k'];
    final out = <String, Object?>{
      for (final k in keys.isEmpty ? data.keys : keys)
        if (data.containsKey(k)) k: data[k],
    };
    if (out.isEmpty) {
      return (
        MessageStatus.error,
        {'message': 'cannot get ${keys.map((k) => '"$k"').join(', ')} through ${body['account']}/$view: no data'},
      );
    }
    return (MessageStatus.success, {'values': out});
  }
}
