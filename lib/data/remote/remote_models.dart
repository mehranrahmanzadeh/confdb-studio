import 'package:flutter/foundation.dart';

import '../../domain/remote.dart';

/// Where the Store's message service is and how Studio talks to it.
@immutable
class RemoteSettings {
  const RemoteSettings({
    this.storeUrl = '',
    this.apiPath = defaultApiPath,
    this.account = '',
    this.tokenCommand = '',
    this.token = '',
    this.signingKey = '',
    this.validity = const Duration(hours: 1),
  });

  factory RemoteSettings.fromJson(Map json) => RemoteSettings(
    storeUrl: json['store-url'] as String? ?? '',
    apiPath: json['api-path'] as String? ?? defaultApiPath,
    account: json['account'] as String? ?? '',
    tokenCommand: json['token-command'] as String? ?? '',
    token: json['token'] as String? ?? '',
    signingKey: json['signing-key'] as String? ?? '',
    validity: Duration(minutes: json['validity-minutes'] as int? ?? 60),
  );

  /// The publisher gateway's messages API below [storeUrl]; `{account}` is
  /// replaced by [account].
  static const defaultApiPath = '/publishergw/v1/brand/{account}/messages';

  /// The Store's base URL, e.g. `http://test-store.lxd`.
  final String storeUrl;
  final String apiPath;

  /// The account that signs requests and owns the sessions.
  final String account;

  /// A shell command printing a macaroon for [account]; `{account}` is
  /// replaced. Run again when the token expires.
  final String tokenCommand;

  /// A pasted macaroon, used when there's no [tokenCommand].
  final String token;

  /// The `snap keys` key requests are signed with.
  final String signingKey;

  /// How long a device may still act on a request.
  final Duration validity;

  bool get hasAuth => tokenCommand.trim().isNotEmpty || token.trim().isNotEmpty;

  /// Everything needed to send a request.
  bool get isComplete => storeUrl.trim().isNotEmpty && account.trim().isNotEmpty && signingKey.trim().isNotEmpty && hasAuth;

  /// `…/messages/sessions`.
  Uri get sessionsUri {
    final base = storeUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final path = apiPath.trim().replaceAll('{account}', Uri.encodeComponent(account.trim())).replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base${path.startsWith('/') ? '' : '/'}$path/sessions');
  }

  /// Whether a session opened with [other] is still usable with these.
  bool sameService(RemoteSettings other) => other.storeUrl == storeUrl && other.apiPath == apiPath && other.account == account;

  RemoteSettings copyWith({
    String? storeUrl,
    String? apiPath,
    String? account,
    String? tokenCommand,
    String? token,
    String? signingKey,
    Duration? validity,
  }) => RemoteSettings(
    storeUrl: storeUrl ?? this.storeUrl,
    apiPath: apiPath ?? this.apiPath,
    account: account ?? this.account,
    tokenCommand: tokenCommand ?? this.tokenCommand,
    token: token ?? this.token,
    signingKey: signingKey ?? this.signingKey,
    validity: validity ?? this.validity,
  );

  Map<String, Object?> toJson() => {
    'store-url': storeUrl,
    'api-path': apiPath,
    'account': account,
    'token-command': tokenCommand,
    'token': token,
    'signing-key': signingKey,
    'validity-minutes': validity.inMinutes,
  };
}

/// A device Studio sends requests to, with an optional friendly name.
@immutable
class RemoteDevice {
  const RemoteDevice(this.id, {this.label = ''});

  factory RemoteDevice.fromJson(Map json) => RemoteDevice(DeviceId.parse(json['id'] as String), label: json['label'] as String? ?? '');

  final DeviceId id;
  final String label;

  /// The label, or the serial.
  String get name => label.isNotEmpty ? label : id.serial;

  Map<String, Object?> toJson() => {'id': id.id, if (label.isNotEmpty) 'label': label};
}

/// Where one device is with one request.
enum DeviceRequestState {
  sending,

  /// The service refused the request, or couldn't be reached.
  notSent,

  /// Sent; the device hasn't answered.
  waiting,

  /// The device didn't answer before the request's `valid-until`.
  expired,
  success,
  error,
  unauthorized,
  rejected;

  bool get isFinal => this != sending && this != waiting;
  bool get isFailure => isFinal && this != success;

  static DeviceRequestState of(MessageStatus s) => switch (s) {
    MessageStatus.success => success,
    MessageStatus.error => error,
    MessageStatus.unauthorized => unauthorized,
    MessageStatus.rejected => rejected,
  };
}

/// A request-message Studio sent, and what the devices answered.
@immutable
class RemoteRequest {
  const RemoteRequest({
    required this.messageId,
    required this.action,
    required this.view,
    required this.devices,
    required this.created,
    required this.validUntil,
    this.keys = const [],
    this.values = const {},
    this.assertion,
    this.sent = false,
    this.sendError,
    this.responses = const {},
  });

  factory RemoteRequest.fromJson(Map json) => RemoteRequest(
    messageId: json['message-id'] as String,
    action: RemoteAction.parse(json['action'] as String? ?? ''),
    view: json['view'] as String,
    devices: [for (final d in json['devices'] as List? ?? const []) d as String],
    created: DateTime.parse(json['created'] as String),
    validUntil: DateTime.parse(json['valid-until'] as String),
    keys: [for (final k in json['keys'] as List? ?? const []) k as String],
    values: (json['values'] as Map?)?.cast<String, Object?>() ?? const {},
    assertion: json['assertion'] as String?,
    sent: json['sent'] as bool? ?? false,
    sendError: json['send-error'] as String?,
    responses: {
      for (final resp in [for (final r in json['responses'] as List? ?? const []) RemoteResponse.fromJson(r as Map)]) resp.device: resp,
    },
  );

  final String messageId;
  final RemoteAction action;

  /// `<account>/<schema>/<view>`.
  final String view;

  /// Device IDs.
  final List<String> devices;
  final DateTime created;
  final DateTime validUntil;

  /// For a `get`: the request paths asked for (all when empty).
  final List<String> keys;

  /// For a `set`: request path → value (`null` unsets).
  final Map<String, Object?> values;

  /// The signed request-message.
  final String? assertion;
  final bool sent;

  /// Why the service didn't take it.
  final String? sendError;

  /// Device ID → its answer.
  final Map<String, RemoteResponse> responses;

  bool expiredAt(DateTime now) => !now.isBefore(validUntil);

  DeviceRequestState stateOf(String device, DateTime now) {
    final r = responses[device];
    if (r != null) return DeviceRequestState.of(r.status);
    if (sendError != null) return DeviceRequestState.notSent;
    if (!sent) return DeviceRequestState.sending;
    return expiredAt(now) ? DeviceRequestState.expired : DeviceRequestState.waiting;
  }

  /// Devices still expected to answer.
  bool isWaitingAt(DateTime now) => sent && sendError == null && !expiredAt(now) && devices.any((d) => !responses.containsKey(d));

  RemoteRequest copyWith({
    String? assertion,
    bool? sent,
    String? sendError,
    bool clearError = false,
    Map<String, RemoteResponse>? responses,
  }) => RemoteRequest(
    messageId: messageId,
    action: action,
    view: view,
    devices: devices,
    created: created,
    validUntil: validUntil,
    keys: keys,
    values: values,
    assertion: assertion ?? this.assertion,
    sent: sent ?? this.sent,
    sendError: clearError ? null : (sendError ?? this.sendError),
    responses: responses ?? this.responses,
  );

  Map<String, Object?> toJson() => {
    'message-id': messageId,
    'action': action.name,
    'view': view,
    'devices': devices,
    'created': created.toUtc().toIso8601String(),
    'valid-until': validUntil.toUtc().toIso8601String(),
    if (keys.isNotEmpty) 'keys': keys,
    if (values.isNotEmpty) 'values': values,
    'assertion': ?assertion,
    'sent': sent,
    'send-error': ?sendError,
    if (responses.isNotEmpty) 'responses': [for (final r in responses.values) r.toJson()],
  };
}

/// Everything the Remote tab keeps between runs.
@immutable
class RemoteState {
  const RemoteState({
    this.settings = const RemoteSettings(),
    this.devices = const [],
    this.requests = const [],
    this.session,
    this.ackToken,
  });

  factory RemoteState.fromJson(Map json) => RemoteState(
    settings: RemoteSettings.fromJson(json['settings'] as Map? ?? const {}),
    devices: [for (final d in json['devices'] as List? ?? const []) ?_tryDevice(d as Map)],
    requests: [for (final r in json['requests'] as List? ?? const []) RemoteRequest.fromJson(r as Map)],
    session: json['session'] as String?,
    ackToken: json['ack-token'] as String?,
  );

  final RemoteSettings settings;
  final List<RemoteDevice> devices;

  /// Newest first.
  final List<RemoteRequest> requests;

  /// The open message session; removing it drops its pending requests, so
  /// it's kept across runs.
  final String? session;

  /// The newest response token seen and saved, acknowledged on the next
  /// exchange.
  final String? ackToken;

  Map<String, Object?> toJson() => {
    'settings': settings.toJson(),
    'devices': [for (final d in devices) d.toJson()],
    'requests': [for (final r in requests) r.toJson()],
    'session': ?session,
    'ack-token': ?ackToken,
  };
}

RemoteDevice? _tryDevice(Map json) {
  try {
    return RemoteDevice.fromJson(json);
  } on FormatException {
    return null;
  }
}
