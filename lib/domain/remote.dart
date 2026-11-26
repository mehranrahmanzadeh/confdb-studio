// Remote confdb management through the Store's message service: device IDs,
// request-message assertions, response-message parsing and the masking of
// secret values in remote answers.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'analysis.dart';
import 'paths.dart';

final _serial = RegExp(r'^[a-zA-Z0-9](?:[:+-]?[a-zA-Z0-9])*$');
final _model = RegExp(r'^[a-zA-Z0-9](?:-?[a-zA-Z0-9])*$');
final _accountId = RegExp(r'^(?:[a-z0-9A-Z]{32}|[-a-z0-9]{2,28})$');

/// A device as the message service addresses it: `<serial>.<model>.<brand-id>`
/// (snapd's `asserts.DeviceID`).
@immutable
class DeviceId {
  const DeviceId(this.serial, this.model, this.brand);

  /// Splits from the right, as snapd does, and checks each part. Throws
  /// [FormatException] naming the part that's wrong.
  factory DeviceId.parse(String raw) {
    final s = raw.trim();
    final last = s.lastIndexOf('.');
    final mid = last <= 0 ? -1 : s.lastIndexOf('.', last - 1);
    if (mid <= 0) throw FormatException('Expected <serial>.<model>.<brand-id>', s);
    final (serial, model, brand) = (s.substring(0, mid), s.substring(mid + 1, last), s.substring(last + 1));
    if (!_serial.hasMatch(serial)) throw FormatException('Invalid serial "$serial"', s);
    if (!_model.hasMatch(model)) throw FormatException('Invalid model "$model"', s);
    if (!_accountId.hasMatch(brand)) throw FormatException('Invalid brand ID "$brand"', s);
    return DeviceId(serial, model, brand);
  }

  static DeviceId? tryParse(String raw) {
    try {
      return DeviceId.parse(raw);
    } on FormatException {
      return null;
    }
  }

  final String serial;
  final String model;
  final String brand;

  String get id => '$serial.$model.$brand';

  @override
  bool operator ==(Object other) => other is DeviceId && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// A device ID typed in, or read from pasted `snap known serial` output.
DeviceId parseDeviceInput(String text) {
  final t = text.trim();
  if (!t.contains('serial:')) return DeviceId.parse(t);
  final headers = parseAssertion(t).headers;
  final (serial, model, brand) = (headers['serial'], headers['model'], headers['brand-id']);
  if (serial is! String || model is! String || brand is! String) {
    throw const FormatException('The serial assertion needs brand-id, model and serial headers');
  }
  return DeviceId.parse('$serial.$model.$brand');
}

const _idChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/// A fresh `message-id` (4–16 letters or digits). The service refuses an ID
/// the account already used, so it's random rather than counted.
String newMessageId([Random? random]) {
  final r = random ?? Random.secure();
  return String.fromCharCodes(List.generate(12, (_) => _idChars.codeUnitAt(r.nextInt(_idChars.length))));
}

enum RemoteAction {
  get,
  set;

  static RemoteAction parse(String s) => s == 'set' ? set : get;
}

/// The JSON body of a `confdb` request-message, as snapd's
/// `confdbstate.confdbAction` reads it.
Map<String, Object?> confdbMessageBody({
  required RemoteAction action,
  required ViewRef view,
  List<String> keys = const [],
  Map<String, Object?> constraints = const {},
  Map<String, Object?> values = const {},
}) => {
  'action': action.name,
  'account': view.account,
  'view': '${view.schema}/${view.view}',
  if (action == RemoteAction.get && keys.isNotEmpty) 'keys': keys,
  if (constraints.isNotEmpty) 'constraints': constraints,
  if (action == RemoteAction.set) 'values': values,
};

/// RFC 3339 in UTC, to the second (`2026-11-25T08:14:18Z`).
String rfc3339(DateTime t) => '${t.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// How far back `valid-since` goes, so a device whose clock runs a little
/// behind still accepts the request.
const clockSkew = Duration(minutes: 5);

/// `snap sign` input for a request-message signed by [account] itself (the
/// only authority snapd accepts for now) and addressed to [devices].
Map<String, Object?> requestMessageHeaders({
  required String account,
  required String messageId,
  required List<DeviceId> devices,
  required Map<String, Object?> body,
  required DateTime now,
  required Duration validFor,
}) => {
  'type': 'request-message',
  'authority-id': account,
  'account-id': account,
  'message-id': messageId,
  'message-kind': 'confdb',
  'devices': [for (final d in devices) d.id],
  'valid-since': rfc3339(now.subtract(clockSkew)),
  'valid-until': rfc3339(now.add(validFor)),
  'timestamp': rfc3339(now),
  'body': jsonEncode(body),
};

/// A serialized assertion split into headers and body; the signature is left
/// out. Handles the flat headers and string lists messages use.
@immutable
class ParsedAssertion {
  const ParsedAssertion(this.headers, this.body);
  final Map<String, Object?> headers;
  final String body;

  String? header(String name) => headers[name] is String ? headers[name] as String : null;
}

ParsedAssertion parseAssertion(String text) {
  final normalized = text.replaceAll('\r\n', '\n');
  final split = normalized.indexOf('\n\n');
  final head = split < 0 ? normalized : normalized.substring(0, split);
  final headers = <String, Object?>{};
  String? listKey;
  for (final line in head.split('\n')) {
    if (line.trim().isEmpty) continue;
    if (line.startsWith(' ')) {
      final item = line.trim();
      if (listKey != null && item.startsWith('- ')) (headers[listKey] as List<String>).add(item.substring(2).trim());
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    if (value.isEmpty) {
      headers[key] = <String>[];
      listKey = key;
    } else {
      headers[key] = value;
      listKey = null;
    }
  }
  var body = '';
  final length = int.tryParse('${headers['body-length'] ?? ''}') ?? 0;
  if (split >= 0 && length > 0) {
    // body-length counts bytes.
    final rest = utf8.encode(normalized.substring(split + 2));
    body = utf8.decode(rest.sublist(0, length.clamp(0, rest.length)), allowMalformed: true);
  }
  return ParsedAssertion(headers, body);
}

/// A response-message's `status` (snapd's `asserts.MessageStatus`).
enum MessageStatus {
  success,

  /// The device accepted the request but the change failed (e.g. a custodian
  /// rejected the write, which rolls it back).
  error,

  /// The device has no confdb-control delegation of the view to the sender.
  unauthorized,

  /// The request was malformed, expired, or out of sequence.
  rejected;

  static MessageStatus parse(String s) => values.firstWhere((v) => v.name == s, orElse: () => rejected);
}

/// One device's answer to a request.
@immutable
class RemoteResponse {
  const RemoteResponse({required this.messageId, required this.device, required this.status, required this.body, this.timestamp});

  /// Reads a response-message assertion. Throws [FormatException] when it
  /// isn't one.
  factory RemoteResponse.fromAssertion(String text) {
    final a = parseAssertion(text);
    if (a.header('type') != 'response-message') throw const FormatException('Not a response-message');
    final id = a.header('message-id');
    final device = a.header('device');
    if (id == null || device == null) throw const FormatException('response-message without message-id or device');
    Map<String, Object?>? body;
    if (a.body.isNotEmpty) {
      try {
        final json = jsonDecode(a.body);
        if (json is Map) body = json.cast<String, Object?>();
      } on FormatException {
        body = {'message': a.body};
      }
    }
    return RemoteResponse(
      messageId: id,
      device: device,
      status: MessageStatus.parse(a.header('status') ?? ''),
      body: body,
      timestamp: DateTime.tryParse(a.header('timestamp') ?? ''),
    );
  }

  factory RemoteResponse.fromJson(Map json) => RemoteResponse(
    messageId: json['message-id'] as String,
    device: json['device'] as String,
    status: MessageStatus.parse(json['status'] as String? ?? ''),
    body: (json['body'] as Map?)?.cast<String, Object?>(),
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? ''),
  );

  /// The request's base ID: a sequenced `abc-2` answers `abc`'s step 2.
  final String messageId;
  final String device;
  final MessageStatus status;
  final Map<String, Object?>? body;
  final DateTime? timestamp;

  /// `values` of a successful `get`.
  Map<String, Object?>? get values => (body?['values'] as Map?)?.cast<String, Object?>();

  /// Why it didn't succeed, as the device put it.
  String? get message => body?['message'] as String?;

  Map<String, Object?> toJson() => {
    'message-id': messageId,
    'device': device,
    'status': status.name,
    'body': ?body,
    if (timestamp != null) 'timestamp': timestamp!.toUtc().toIso8601String(),
  };
}

/// Every leaf of a `get` answer as `(path, value)`, e.g. `('https.url', '…')`.
/// Lists and empty maps are leaves.
List<(String, Object?)> flattenValues(Map<String, Object?> values, [String prefix = '']) => [
  for (final e in values.entries)
    if (e.value is Map && (e.value as Map).isNotEmpty)
      ...flattenValues((e.value as Map).cast<String, Object?>(), joinTreePath(prefix, e.key))
    else
      (joinTreePath(prefix, e.key), e.value),
];

/// Whether [path] (a request path a device answered with, possibly below a
/// rule's own request) reaches storage that [schema] marks secret through
/// [view]. A remote `get` runs with admin access, so the device sends secrets
/// back; this decides what the app keeps masked.
bool isSecretRequestPath(ConfdbSchema schema, String view, String path) {
  final def = schema.view(view);
  final segs = tryParsePath(path);
  if (def == null || segs == null) return false;
  for (final rule in def.rules) {
    final ruleSegs = tryParsePath(rule.request);
    if (ruleSegs == null) continue;
    if (ruleSegs.length <= segs.length) {
      // The answer is at or below the rule: map the rest onto its storage.
      final m = matchRequest(rule.request, joinPath(segs.take(ruleSegs.length)));
      if (m == null || m.suffix.isNotEmpty) continue;
      final storage = fillPath(rule.storage, m.bindings, segs.sublist(ruleSegs.length));
      if (_secretAlong(schema.storage, storage)) return true;
    } else if (matchRequest(rule.request, path) case final m?) {
      // The answer contains the rule's data: secret if anything below is.
      final node = resolveStoragePath(schema.storage, fillPath(rule.storage, m.bindings));
      if (node != null && (node.secret || _anyDescendantSecret(node))) return true;
    }
  }
  return false;
}

bool _secretAlong(StorageNode root, String storage) {
  final segs = tryParsePath(storage) ?? const <PathSegment>[];
  for (var i = 1; i <= segs.length; i++) {
    final n = resolveStoragePath(root, joinPath(segs.take(i)));
    if (n != null && n.secret) return true;
  }
  return false;
}

bool _anyDescendantSecret(StorageNode n) {
  for (final (_, _, d) in n.walk()) {
    if (d.secret) return true;
  }
  final e = n.kind == StorageKind.array ? n.element : null;
  return e != null && (e.secret || _anyDescendantSecret(e));
}
