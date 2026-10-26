import '../models.dart';

/// Account fields the Store's `whoami`/`account` endpoints return, as the
/// vendored Rust backend parses them.
class StoreAccountInfo {
  const StoreAccountInfo({
    required this.id,
    required this.email,
    required this.username,
    required this.displayName,
    required this.permissions,
    required this.channels,
    required this.expires,
  });

  factory StoreAccountInfo.fromJson(Map json) => StoreAccountInfo(
    id: json['id'] as String? ?? '',
    email: json['email'] as String? ?? '',
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    permissions: [for (final p in json['permissions'] as List? ?? const []) '$p'],
    channels: [for (final c in json['channels'] as List? ?? const []) '$c'],
    expires: json['expires'] as String? ?? '',
  );

  final String id;
  final String email;
  final String username;
  final String displayName;
  final List<String> permissions;
  final List<String> channels;
  final String expires;
}

/// A raw `{status, body}` pair from [StoreAuthClient.request], uninterpreted
/// so the caller can parse success and error bodies itself (same contract
/// the old `store_helper.py request` command had).
class StoreApiResponse {
  const StoreApiResponse({required this.status, required this.body});
  final int status;
  final String body;
}

/// What a successful login or credential restore yields: the account and
/// the opaque blob to persist for the next launch.
class StoreAuthSession {
  const StoreAuthSession({required this.account, required this.credentialsJson});
  final StoreAccountInfo account;

  /// Save this verbatim; hand it back to [StoreAuthClient.restoreCredentials]
  /// on the next launch. Treat it as an opaque bearer credential.
  final String credentialsJson;
}

/// Ubuntu One SSO login + macaroon-authenticated Snap Store requests.
///
/// [SnapstoreAuthClient] is the real (FFI, `snapstore-auth` package)
/// implementation; tests use a fake. The whole authentication session
/// (which store/login URLs are in play) is process-wide and fixed by
/// whichever [StoreEnv] the *first* call in the process uses — see
/// [SnapstoreAuthClient]'s class doc.
abstract interface class StoreAuthClient {
  /// Ubuntu One login. Throws [ConfdbException] with
  /// [ConfdbErrorKind.twoFactorRequired] when the account needs a one-time
  /// code and [otp] is missing or wrong.
  Future<StoreAuthSession> login({required StoreEnv env, required String email, required String password, String? otp});

  /// Abandons an in-progress [login] left waiting on a 2FA code (e.g. the
  /// user closed the dialog instead of entering one). Safe to call when
  /// nothing is in progress.
  Future<void> cancelLogin();

  /// Validates and activates a previously saved [StoreAuthSession.credentialsJson].
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson});

  /// Ends the session. Safe to call when already signed out.
  Future<void> logout();

  /// `GET /api/v2/tokens/whoami` with the active credentials.
  Future<StoreAccountInfo> whoami();

  /// `GET /dev/api/account`: the signed-in account's details, as the raw
  /// JSON document — including `account_keys[].{name, public-key-sha3-384}`,
  /// the account-keys already registered to it.
  Future<Map<String, Object?>> accountInfo();

  /// `POST /dev/api/account/account-key`: registers a serialized
  /// `account-key-request` assertion — the output of `snap export-key` on
  /// the host — to the signed-in account.
  Future<void> registerKey(String accountKeyRequest);

  /// An arbitrary authenticated request, e.g.
  /// `request('GET', '/api/v2/confdb-schemas')`. Returns the raw response
  /// for any HTTP status; only transport-level failures throw.
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType});
}
