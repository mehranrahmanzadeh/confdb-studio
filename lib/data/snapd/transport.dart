// Two ways to reach snapd's REST API: the unix socket directly, or through
// the `snap` command (`snap debug api`), which also works where the socket
// isn't reachable from the app and picks up the user's snap login.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';

/// A decoded snapd response: `{"type", "status-code", "result", "change"}`.
class SnapdResponse {
  const SnapdResponse({required this.type, required this.statusCode, required this.result, this.change});

  factory SnapdResponse.fromJson(Map json) => SnapdResponse(
    type: json['type'] as String? ?? 'sync',
    statusCode: json['status-code'] as int? ?? 200,
    result: json['result'],
    change: json['change'] as String?,
  );

  final String type;
  final int statusCode;
  final Object? result;

  /// Change ID for async responses.
  final String? change;

  bool get isError => type == 'error';
  String get errorKind => (result is Map ? (result as Map)['kind'] : null) as String? ?? '';
  String get errorMessage => (result is Map ? (result as Map)['message'] : null) as String? ?? 'snapd returned status $statusCode';
}

abstract interface class SnapdTransport {
  /// Shown in the UI, e.g. "snapd REST".
  String get name;

  /// [interactive] lets snapd ask for admin authentication through polkit.
  /// [rawBody] is sent as-is with [contentType] (assertions); otherwise
  /// [body] is JSON-encoded.
  Future<SnapdResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? rawBody,
    String contentType = 'application/json',
    bool interactive = false,
  });

  void close();
}

String _pathWithQuery(String path, Map<String, String>? query) =>
    query == null || query.isEmpty ? path : '$path?${Uri(queryParameters: query).query}';

/// Talks HTTP over `/run/snapd.socket`.
class UnixSocketTransport implements SnapdTransport {
  UnixSocketTransport({this.socketPath = '/run/snapd.socket'}) {
    _client.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
  }

  final String socketPath;
  final _client = HttpClient();

  @override
  String get name => 'snapd REST';

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
    final HttpClientRequest req;
    try {
      req = await _client.openUrl(method, Uri.parse('http://localhost${_pathWithQuery(path, query)}'));
    } on SocketException catch (e) {
      throw ConfdbException(
        'snapd didn’t respond on `$socketPath` (${e.osError?.message ?? e.message}).',
        command: 'systemctl status snapd.service',
        kind: ConfdbErrorKind.unreachable,
      );
    }
    if (interactive) req.headers.set('X-Allow-Interaction', 'true');
    final payload = rawBody ?? (body == null ? null : jsonEncode(body));
    if (payload != null) {
      req.headers.contentType = ContentType.parse(contentType);
      req.write(payload);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return _decode(text, res.statusCode);
  }

  @override
  void close() => _client.close(force: true);
}

/// Runs `snap debug api`, with `pkexec` in front for interactive (privileged) calls.
class SnapCommandTransport implements SnapdTransport {
  SnapCommandTransport({this.snap = 'snap', this.pkexec = 'pkexec'});

  final String snap;
  final String pkexec;

  @override
  String get name => 'snap command';

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
    final payload = rawBody ?? (body == null ? null : jsonEncode(body));
    final args = [
      'debug',
      'api',
      '-X',
      method,
      if (payload != null) ...['-H', 'Content-Type: $contentType'],
      _pathWithQuery(path, query),
    ];
    // Writes that need root go through pkexec; snapd treats root as authorised.
    final exe = interactive && method != 'GET' ? pkexec : snap;
    final fullArgs = exe == pkexec ? [snap, ...args] : args;
    final Process proc;
    try {
      proc = await Process.start(exe, fullArgs);
    } on ProcessException catch (e) {
      throw ConfdbException('Couldn’t run `$exe`: ${e.message}', kind: ConfdbErrorKind.unreachable);
    }
    if (payload != null) proc.stdin.write(payload);
    await proc.stdin.close();
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    final text = await out;
    if (text.trim().isEmpty) {
      final msg = (await err).trim();
      if (exe == pkexec && (code == 126 || code == 127)) {
        throw const ConfdbException('Authentication was cancelled.', kind: ConfdbErrorKind.permissionDenied);
      }
      throw ConfdbException(msg.isEmpty ? '`snap debug api` exited with status $code' : msg, kind: ConfdbErrorKind.unreachable);
    }
    return _decode(text, null);
  }

  @override
  void close() {}
}

SnapdResponse _decode(String text, int? httpStatus) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw ConfdbException('snapd sent a response that isn’t JSON (status ${httpStatus ?? '?'}).');
  }
  if (json is! Map) throw const ConfdbException('snapd sent an unexpected response.');
  return SnapdResponse.fromJson(json);
}
