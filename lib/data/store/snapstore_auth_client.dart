import 'dart:isolate';

import 'package:snapstore_auth/snapstore_auth.dart' as ssa;

import '../models.dart';
import 'store_auth_client.dart';

/// Maps the package's `SnapstoreAuthError.kind` (the Rust
/// `AuthenticationError` enum's wire tag) onto [ConfdbErrorKind].
ConfdbErrorKind _kindOf(String kind, {int? status}) => switch (kind) {
  'network' => ConfdbErrorKind.offline,
  // The store answers 401 once the persisted macaroon's SSO discharge has
  // expired or been revoked; there is no silent-refresh path (the SSO
  // discharge caveat isn't reissued short of a fresh login), so this is
  // surfaced the same way `credentials_rejected`/`no_active_session` are:
  // as "signed out", which sends the user back through the login dialog.
  'http' => status == 401 ? ConfdbErrorKind.signedOut : ConfdbErrorKind.other,
  'credentials_rejected' => ConfdbErrorKind.signedOut,
  'two_factor_required' => ConfdbErrorKind.twoFactorRequired,
  'no_active_session' => ConfdbErrorKind.signedOut,
  'session_cancelled' => ConfdbErrorKind.other,
  _ => ConfdbErrorKind.other,
};

/// Builds the [ConfdbException] the rest of the app expects from a
/// `{kind, detail, httpStatus}` triple — the same fields
/// [ssa.SnapstoreAuthError] carries, but passed as plain values so
/// [_blocking] never has to send a custom exception object across an
/// isolate boundary (see its doc comment).
ConfdbException _errorFromParts(String kind, String detail, int? status) {
  final message = status == 401
      ? 'The Snap Store login has expired or was revoked. Sign in again.\n$detail'
      : status == null
      ? detail
      : 'HTTP $status: $detail';
  return ConfdbException(message, kind: _kindOf(kind, status: status));
}

/// Turns a [ssa.SnapstoreAuthError] into the [ConfdbException] the rest of
/// the app expects.
ConfdbException _errorFrom(ssa.SnapstoreAuthError e) => _errorFromParts(e.kind, e.detail, e.httpStatus);

/// Runs [body] on a fresh background isolate, re-initializing the package's
/// runtime handle there first.
///
/// `auth_runtime_init` is a process-wide one-shot singleton (first caller's
/// config wins; later calls just hand back the same handle — see the
/// package's `SnapstoreAuth.init` doc), but [ssa.SnapstoreAuth.instance] is
/// backed by a *Dart static* bound per-isolate, so a freshly spawned
/// isolate can't just call `.instance`; it must call `.init` again (with
/// the same [storeUrl]) to get its own handle onto that same Rust runtime.
///
/// [body] must return a plain [Map]/[List]/primitive — not a custom class
/// instance — since only JSON-safe values are guaranteed sendable back
/// across the isolate boundary. For the same reason, a thrown
/// [ssa.SnapstoreAuthError] is caught *inside* the spawned isolate and its
/// fields are carried back as plain values, never the exception object
/// itself.
Future<Map<String, Object?>> _blocking(String? storeUrl, Map<String, Object?> Function(ssa.SnapstoreAuth auth) body) async {
  final result = await Isolate.run(() {
    try {
      final auth = ssa.SnapstoreAuth.init(storeUrl: storeUrl);
      return (ok: true, value: body(auth), kind: '', detail: '', status: null as int?);
    } on ssa.SnapstoreAuthError catch (e) {
      return (ok: false, value: const <String, Object?>{}, kind: e.kind, detail: e.detail, status: e.httpStatus);
    } on Object catch (e) {
      return (ok: false, value: const <String, Object?>{}, kind: '_local', detail: '$e', status: null as int?);
    }
  });
  if (!result.ok) {
    if (result.kind == '_local') {
      throw ConfdbException('Could not use the Snap Store backend: ${result.detail}', kind: ConfdbErrorKind.unsupported);
    }
    throw _errorFromParts(result.kind, result.detail, result.status);
  }
  return result.value;
}

/// Real [StoreAuthClient] backed by `snapstore_auth`
/// (https://github.com/ogra1/snapstore-auth), a Rust/`dart:ffi` crate for
/// Ubuntu One SSO login and macaroon-signed Snap Store requests, pulled in
/// as a git dependency (see `pubspec.yaml`) rather than vendored in this
/// repo.
///
/// **Process-wide environment limitation**: the underlying
/// `auth_runtime_init` is a one-shot singleton — the first call's
/// `store_url`/`login_url` wins for the lifetime of the process, and later
/// calls are no-ops. This means [StoreEnv.production] and
/// [StoreEnv.staging] can't both be used in one run of the app. This class
/// tracks which env first initialized the runtime and throws a
/// [ConfdbException] with [ConfdbErrorKind.unsupported] if asked to use a
/// different one, telling the user to restart instead of silently talking
/// to the wrong store.
class SnapstoreAuthClient implements StoreAuthClient {
  StoreEnv? _activeEnv;

  /// Whether a previous [login] call left the state machine parked in
  /// `needs2faCode` (credentials accepted, waiting on a one-time code). The
  /// machine lives on the process-wide runtime handle, not per-call state,
  /// so the *next* [login] call — once the UI has the code — must resume
  /// it with `submit2faCode` only. Reissuing `startLogin`/
  /// `submitCredentials` while parked there is an illegal transition.
  bool _awaitingOtp = false;

  /// Tracks whether the machine has reached `succeeded` (via [login] or
  /// [restoreCredentials]); cleared on [logout].
  ///
  /// A caller can legitimately ask to [login] again while already signed
  /// in — e.g. a UI retry prompted by some *other* call's 401: the
  /// persisted macaroon is known stale (that's exactly why we're here), so
  /// reusing it would just repeat the failure. Reissuing `startLogin` on an
  /// already-`succeeded` machine is also an illegal transition, so [login]
  /// always logs out first when this is set, discarding the stale macaroon
  /// before the fresh attempt — never short-circuiting to the old
  /// credentials.
  bool _signedIn = false;

  String? _storeUrlFor(StoreEnv env) => env == StoreEnv.staging ? 'https://${env.host}' : null;

  ssa.SnapstoreAuth _ensureInitialized(StoreEnv env) {
    if (_activeEnv != null) {
      if (_activeEnv != env) {
        throw ConfdbException(
          'Already signed in against ${_activeEnv!.label}; restart Confdb Studio '
          'to use ${env.label} instead (the Snap Store backend only supports one '
          'environment per run).',
          kind: ConfdbErrorKind.unsupported,
        );
      }
      return ssa.SnapstoreAuth.instance;
    }
    try {
      final auth = ssa.SnapstoreAuth.init(storeUrl: _storeUrlFor(env));
      _activeEnv = env;
      return auth;
    } on Object catch (e) {
      throw ConfdbException('Could not use the Snap Store backend: $e', kind: ConfdbErrorKind.unsupported);
    }
  }

  /// Polls `drainEvents` until a terminal event (`succeeded`, `failed`,
  /// `cancelled`, `needs_2fa_code`) appears, since the crate only exposes
  /// polling (no push/stream FFI primitive).
  Future<ssa.MachineEvent> _awaitTerminalEvent(ssa.SnapstoreAuth auth) async {
    while (true) {
      for (final event in auth.drainEvents()) {
        switch (event) {
          case ssa.SucceededEvent():
          case ssa.FailedEvent():
          case ssa.CancelledEvent():
          case ssa.Needs2faCodeEvent():
            return event;
          case ssa.NeedsCredentialsEvent():
          case ssa.LoggedOutEvent():
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  StoreAuthSession _sessionFromSucceeded(ssa.SucceededEvent event, StoreAccountInfo account) {
    _signedIn = true;
    return StoreAuthSession(account: account, credentialsJson: event.credentialsJson);
  }

  @override
  Future<StoreAuthSession> login({required StoreEnv env, required String email, required String password, String? otp}) async {
    final auth = _ensureInitialized(env);

    ssa.MachineEvent event;
    if (_awaitingOtp) {
      // Resume the parked machine with just the code instead of restarting
      // the whole login (see [_awaitingOtp]'s doc comment).
      if (otp == null || otp.isEmpty) {
        throw const ConfdbException('This account needs a two-factor authentication code.', kind: ConfdbErrorKind.twoFactorRequired);
      }
      event = await _submitOtp(auth, otp);
    } else {
      // A fresh attempt. Discard any backlog left over from a flow the UI
      // abandoned without [cancelLogin] (e.g. the dialog was closed while
      // parked waiting on a 2FA code) — otherwise a stale buffered event
      // from that abandoned attempt could be misread as this attempt's
      // outcome by [_awaitTerminalEvent] below.
      auth.drainEvents();

      if (_signedIn) {
        // Already `succeeded` (see [_signedIn]'s doc comment): log out
        // first so the fresh credentials actually get used, rather than
        // reissuing `startLogin` straight into the "already logged in"
        // guard, or silently reusing a macaroon we know is bad.
        _signedIn = false;
        _call(auth.logout);
      }

      _call(auth.startLogin);
      _call(() => auth.submitCredentials(email, password));

      event = await _awaitTerminalEvent(auth);

      if (event is ssa.Needs2faCodeEvent) {
        if (otp == null || otp.isEmpty) {
          _awaitingOtp = true;
          throw const ConfdbException('This account needs a two-factor authentication code.', kind: ConfdbErrorKind.twoFactorRequired);
        }
        event = await _submitOtp(auth, otp);
      }
    }

    if (event is ssa.Needs2faCodeEvent) {
      // Wrong/expired code: the machine is parked at `needs2faCode` again,
      // ready for another `submit2faCode` resume.
      _awaitingOtp = true;
      throw const ConfdbException('That code wasn’t accepted. Try again.', kind: ConfdbErrorKind.twoFactorRequired);
    }
    _awaitingOtp = false;

    switch (event) {
      case ssa.FailedEvent(:final error):
        throw _errorFrom(error);
      case ssa.CancelledEvent():
        throw const ConfdbException('The sign-in attempt was cancelled.', kind: ConfdbErrorKind.other);
      case ssa.SucceededEvent():
        final account = await whoami();
        return _sessionFromSucceeded(event, account);
      case ssa.NeedsCredentialsEvent():
      case ssa.LoggedOutEvent():
      case ssa.Needs2faCodeEvent():
        throw ConfdbException('Unexpected sign-in state: $event');
    }
  }

  /// Submits a one-time code to the already-parked `needs2faCode` state and
  /// waits for the next terminal event.
  Future<ssa.MachineEvent> _submitOtp(ssa.SnapstoreAuth auth, String otp) async {
    _call(() => auth.submit2faCode(otp));
    return _awaitTerminalEvent(auth);
  }

  /// Calls a package command, mapping [ssa.SnapstoreAuthError] onto
  /// [ConfdbException].
  void _call(void Function() fn) {
    try {
      fn();
    } on ssa.SnapstoreAuthError catch (e) {
      throw _errorFrom(e);
    }
  }

  @override
  Future<void> cancelLogin() async {
    if (!_awaitingOtp) return; // nothing parked mid-flow to abandon
    _awaitingOtp = false;
    try {
      // Only reachable while parked at `needs2faCode` (see the guard
      // above): valid there, resets the machine to `idle`. Sending it
      // while `succeeded` would instead tear down the runtime's driver
      // loop, so this must never fire once [_signedIn] is set.
      _call(ssa.SnapstoreAuth.instance.cancel);
    } on ConfdbException {
      // Best-effort: whatever state the machine ends up in, the next
      // [login] call starts a fresh attempt and flushes any stray events.
    }
  }

  @override
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson}) async {
    final auth = _ensureInitialized(env);
    _call(() => auth.restoreCredentials(credentialsJson));
    _signedIn = true;
    final account = await whoami();
    return StoreAuthSession(account: account, credentialsJson: credentialsJson);
  }

  @override
  Future<void> logout() async {
    _signedIn = false;
    _awaitingOtp = false;
    if (_activeEnv == null) return;
    _call(ssa.SnapstoreAuth.instance.logout);
  }

  @override
  Future<StoreAccountInfo> whoami() async {
    final env = _activeEnv;
    if (env == null) throw const ConfdbException('Not signed in to the Snap Store.', kind: ConfdbErrorKind.signedOut);
    final map = await _blocking(_storeUrlFor(env), (auth) {
      final a = auth.whoami();
      return {
        'id': a.id,
        'email': a.email,
        'username': a.username,
        'display_name': a.displayName,
        'permissions': a.permissions,
        'channels': a.channels,
        'expires': a.expires,
      };
    });
    return StoreAccountInfo.fromJson(map);
  }

  @override
  Future<Map<String, Object?>> accountInfo() async {
    final env = _activeEnv;
    if (env == null) throw const ConfdbException('Not signed in to the Snap Store.', kind: ConfdbErrorKind.signedOut);
    return _blocking(_storeUrlFor(env), (auth) => auth.accountInfoRaw());
  }

  @override
  Future<void> registerKey(String accountKeyRequest) async {
    final env = _activeEnv;
    if (env == null) throw const ConfdbException('Not signed in to the Snap Store.', kind: ConfdbErrorKind.signedOut);
    await _blocking(_storeUrlFor(env), (auth) {
      auth.registerKey(accountKeyRequest);
      return const {};
    });
  }

  @override
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType}) async {
    final env = _activeEnv;
    if (env == null) throw const ConfdbException('Not signed in to the Snap Store.', kind: ConfdbErrorKind.signedOut);
    final result = await _blocking(_storeUrlFor(env), (auth) {
      final r = auth.request(method, path, body: body, contentType: contentType);
      return {'status': r.status, 'body': r.body};
    });
    return StoreApiResponse(status: result['status'] as int? ?? 0, body: result['body'] as String? ?? '');
  }
}
