import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'remote_models.dart';

/// A message service failure. [status] is the HTTP status, when there was
/// one.
class MessageServiceException extends ConfdbException {
  const MessageServiceException(super.message, {this.status, super.kind, super.command});

  final int? status;

  /// The session doesn't exist (any more).
  bool get sessionGone => status == 404;

  /// A message ID was used before.
  bool get duplicateId => status == 409;
}

/// One response-message waiting in a session.
class QueuedMessage {
  const QueuedMessage({required this.data, required this.token});
  final String data;

  /// Acknowledges this and every earlier message when passed as `after`.
  final String token;
}

class ExchangeResult {
  const ExchangeResult({required this.messages, required this.hasMore});
  final List<QueuedMessage> messages;

  /// More responses are queued than were returned.
  final bool hasMore;
}

/// The account side of the Store's message service: sessions and the
/// exchange that sends requests, acknowledges and fetches responses.
abstract interface class MessageService {
  Future<String> createSession();
  Future<void> removeSession(String session);

  /// Routes [send] (signed request-messages) to their devices, drops the
  /// responses up to [after] and returns up to [limit] more. All of [send]
  /// is refused if any is invalid.
  Future<ExchangeResult> exchange(String session, {int limit = 0, String? after, List<String> send = const []});
}

/// Signs `snap sign` input with a key from the host's keyring.
abstract interface class RequestSigner {
  Future<String> sign(Map<String, Object?> headers, String key);
}

/// Keeps the Remote tab's state.
abstract interface class RemoteStorage {
  Future<RemoteState?> load();
  Future<void> save(RemoteState state);
}

/// Talks to the message service over HTTP, with a macaroon from the
/// settings' token command or pasted token.
class HttpMessageService implements MessageService {
  HttpMessageService(this.settings, {TokenSource? tokens, HttpClient? client})
    : tokens = tokens ?? TokenSource(settings),
      _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final RemoteSettings settings;
  final TokenSource tokens;
  final HttpClient _client;

  @override
  Future<String> createSession() async {
    final json = await _post(settings.sessionsUri, {'action': 'create'});
    final session = json is Map ? json['session'] : null;
    if (session is! String || session.isEmpty) throw const MessageServiceException('The message service returned no session ID');
    return session;
  }

  @override
  Future<void> removeSession(String session) => _post(settings.sessionsUri, {'action': 'remove', 'session': session});

  @override
  Future<ExchangeResult> exchange(String session, {int limit = 0, String? after, List<String> send = const []}) async {
    final json = await _post(settings.sessionsUri.replace(path: '${settings.sessionsUri.path}/${Uri.encodeComponent(session)}/exchange'), {
      'limit': limit,
      'after': ?after,
      if (send.isNotEmpty)
        'messages': [
          for (final m in send) {'format': 'assertion', 'data': m},
        ],
    });
    final map = json is Map ? json : const {};
    return ExchangeResult(
      hasMore: map['has-pending-messages'] == true,
      messages: [
        for (final m in map['messages'] as List? ?? const [])
          if (m is Map && m['data'] is String && m['token'] is String)
            QueuedMessage(data: m['data'] as String, token: m['token'] as String),
      ],
    );
  }

  Future<Object?> _post(Uri uri, Map<String, Object?> body) async {
    var (status, text) = await _send(uri, body, await tokens.token());
    if (status == 401 && tokens.canRefresh) {
      (status, text) = await _send(uri, body, await tokens.token(refresh: true));
    }
    if (status >= 200 && status < 300) {
      if (text.trim().isEmpty) return null;
      try {
        return jsonDecode(text);
      } on FormatException {
        throw MessageServiceException('The message service sent something that isn\'t JSON (HTTP $status)', status: status);
      }
    }
    throw MessageServiceException(
      _errorMessage(status, text),
      status: status,
      kind: status == 401 || status == 403 ? ConfdbErrorKind.signedOut : (status == 404 ? ConfdbErrorKind.notFound : ConfdbErrorKind.other),
    );
  }

  Future<(int, String)> _send(Uri uri, Map<String, Object?> body, String token) async {
    try {
      final req = await _client.postUrl(uri);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Macaroon $token')
        ..contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 30));
      return (res.statusCode, await res.transform(utf8.decoder).join());
    } on SocketException catch (e) {
      throw MessageServiceException('Couldn\'t reach ${uri.host}: ${e.osError?.message ?? e.message}', kind: ConfdbErrorKind.offline);
    } on HttpException catch (e) {
      throw MessageServiceException('Couldn\'t reach ${uri.host}: ${e.message}', kind: ConfdbErrorKind.offline);
    } on TimeoutException {
      throw MessageServiceException('${uri.host} didn\'t answer in time', kind: ConfdbErrorKind.offline);
    }
  }

  void close() => _client.close(force: true);
}

/// `error-list` messages, or the status when there are none.
String _errorMessage(int status, String text) {
  try {
    final json = jsonDecode(text);
    final list = json is Map ? json['error-list'] : null;
    if (list is List) {
      final msgs = [
        for (final e in list)
          if (e is Map && e['message'] is String) e['message'] as String,
      ];
      if (msgs.isNotEmpty) return msgs.join('\n');
    }
  } on FormatException {
    // Not JSON: fall through.
  }
  return switch (status) {
    401 => 'The message service didn\'t accept the token (HTTP 401). Check the token settings.',
    403 => 'The token isn\'t allowed to use this account\'s messages (HTTP 403)',
    404 => 'Not found (HTTP 404). Check the Store URL and API path.',
    _ => 'The message service answered HTTP $status${text.trim().isEmpty ? '' : ': ${text.trim().split('\n').first}'}',
  };
}

/// The macaroon for the message service: the pasted token, or the token
/// command's output, kept until it's close to expiring.
class TokenSource {
  TokenSource(this.settings, {this.lifetime = const Duration(minutes: 55), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final RemoteSettings settings;

  /// How long a command's token is reused.
  final Duration lifetime;
  final DateTime Function() _clock;
  String? _token;
  DateTime? _fetched;

  String get _command => settings.tokenCommand.trim().replaceAll('{account}', settings.account.trim());

  bool get canRefresh => _command.isNotEmpty;

  Future<String> token({bool refresh = false}) async {
    if (!canRefresh) {
      final t = settings.token.trim();
      if (t.isEmpty) {
        throw const MessageServiceException('Set a token or a token command in Remote settings', kind: ConfdbErrorKind.signedOut);
      }
      return t;
    }
    final now = _clock();
    if (!refresh && _token != null && now.difference(_fetched!) < lifetime) return _token!;
    final ProcessResult r;
    try {
      r = await Process.run('sh', ['-c', _command]).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw MessageServiceException('The token command took too long', command: _command, kind: ConfdbErrorKind.signedOut);
    }
    final out = '${r.stdout}'.trim();
    if (r.exitCode != 0 || out.isEmpty || out == 'null') {
      final err = '${r.stderr}'.trim();
      throw MessageServiceException(
        'The token command failed${err.isEmpty ? '' : ': ${err.split('\n').last}'}',
        command: _command,
        kind: ConfdbErrorKind.signedOut,
      );
    }
    _token = out.split('\n').last.trim();
    _fetched = now;
    return _token!;
  }
}

/// Signs with `snap sign -k <key>`.
class SnapRequestSigner implements RequestSigner {
  const SnapRequestSigner({this.snapCommand = 'snap'});
  final String snapCommand;

  @override
  Future<String> sign(Map<String, Object?> headers, String key) async {
    final Process proc;
    try {
      proc = await Process.start(snapCommand, ['sign', '-k', key]);
    } on ProcessException catch (e) {
      throw ConfdbException('Couldn\'t run `snap sign`: ${e.message}', command: 'snap sign -k $key');
    }
    proc.stdin.write(jsonEncode(headers));
    await proc.stdin.close();
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    if (await proc.exitCode != 0) {
      throw ConfdbException('`snap sign` failed: ${(await err).trim()}', command: 'snap sign -k $key');
    }
    return out;
  }
}

/// Keeps the state in a JSON file only the user can read: it holds the
/// token, if one was pasted, and the values sent and received.
class FileRemoteStorage implements RemoteStorage {
  FileRemoteStorage(this.path);
  final String path;

  @override
  Future<RemoteState?> load() async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString());
      return json is Map ? RemoteState.fromJson(json) : null;
    } on Object {
      // A damaged file shouldn't keep the tab from opening.
      return null;
    }
  }

  @override
  Future<void> save(RemoteState state) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(state.toJson()));
    await Process.run('chmod', ['600', tmp.path]);
    await tmp.rename(path);
  }
}

class MemoryRemoteStorage implements RemoteStorage {
  MemoryRemoteStorage([this.state]);
  RemoteState? state;

  @override
  Future<RemoteState?> load() async => state;

  @override
  Future<void> save(RemoteState state) async => this.state = state;
}
