import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../models.dart';
import 'store_auth_client.dart';

// ===========================================================================
// Native bindings for the vendored `rust/` `snapstore-auth` crate (see
// `rust/src/lib.rs`'s `ffi` module for the authoritative C-ABI surface this
// must mirror exactly).
// ===========================================================================

typedef _RuntimeInitNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<pkg_ffi.Utf8> storeUrl,
  ffi.Pointer<pkg_ffi.Utf8> loginUrl,
  ffi.Pointer<pkg_ffi.Utf8> permissions,
  ffi.Pointer<pkg_ffi.Utf8> storageKey,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);
typedef _RuntimeInitDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<pkg_ffi.Utf8> storeUrl,
  ffi.Pointer<pkg_ffi.Utf8> loginUrl,
  ffi.Pointer<pkg_ffi.Utf8> permissions,
  ffi.Pointer<pkg_ffi.Utf8> storageKey,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);

typedef _RuntimeGetNative = ffi.Pointer<ffi.Void> Function();
typedef _RuntimeGetDart = ffi.Pointer<ffi.Void> Function();

typedef _HandleOutErrToBoolNative = ffi.Bool Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr);
typedef _HandleOutErrToBoolDart = bool Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr);

typedef _SubmitCredentialsNative = ffi.Bool Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> email,
  ffi.Pointer<pkg_ffi.Utf8> password,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);
typedef _SubmitCredentialsDart = bool Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> email,
  ffi.Pointer<pkg_ffi.Utf8> password,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);

typedef _OneArgToBoolNative = ffi.Bool Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> arg,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);
typedef _OneArgToBoolDart = bool Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> arg,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);

typedef _HandleOutErrToStringNative = ffi.Pointer<pkg_ffi.Utf8> Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);
typedef _HandleOutErrToStringDart = ffi.Pointer<pkg_ffi.Utf8> Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);

typedef _DrainEventsNative = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void> handle);
typedef _DrainEventsDart = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void> handle);

typedef _PendingEventsNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void> handle);
typedef _PendingEventsDart = int Function(ffi.Pointer<ffi.Void> handle);

typedef _RequestNative = ffi.Pointer<pkg_ffi.Utf8> Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> method,
  ffi.Pointer<pkg_ffi.Utf8> path,
  ffi.Pointer<pkg_ffi.Utf8> body,
  ffi.Pointer<pkg_ffi.Utf8> contentType,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);
typedef _RequestDart = ffi.Pointer<pkg_ffi.Utf8> Function(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<pkg_ffi.Utf8> method,
  ffi.Pointer<pkg_ffi.Utf8> path,
  ffi.Pointer<pkg_ffi.Utf8> body,
  ffi.Pointer<pkg_ffi.Utf8> contentType,
  ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
);

typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<pkg_ffi.Utf8> s);
typedef _FreeStringDart = void Function(ffi.Pointer<pkg_ffi.Utf8> s);

/// Resolved symbols from one `libsnapstore_auth.so`, cached per path so
/// repeated lookups (including from spawned isolates) don't re-`dlopen`.
class _Native {
  factory _Native(String libraryPath) => _cache.putIfAbsent(libraryPath, () => _Native._(libraryPath));

  _Native._(String libraryPath) : _lib = ffi.DynamicLibrary.open(libraryPath) {
    runtimeInit = _lib.lookupFunction<_RuntimeInitNative, _RuntimeInitDart>('auth_runtime_init');
    runtimeGet = _lib.lookupFunction<_RuntimeGetNative, _RuntimeGetDart>('auth_runtime_get');
    startLogin = _lib.lookupFunction<_HandleOutErrToBoolNative, _HandleOutErrToBoolDart>('auth_start_login');
    submitCredentials = _lib.lookupFunction<_SubmitCredentialsNative, _SubmitCredentialsDart>('auth_submit_credentials');
    submit2faCode = _lib.lookupFunction<_OneArgToBoolNative, _OneArgToBoolDart>('auth_submit_2fa_code');
    restoreCredentials = _lib.lookupFunction<_OneArgToBoolNative, _OneArgToBoolDart>('auth_restore_credentials');
    logout = _lib.lookupFunction<_HandleOutErrToBoolNative, _HandleOutErrToBoolDart>('auth_logout');
    cancel = _lib.lookupFunction<_HandleOutErrToBoolNative, _HandleOutErrToBoolDart>('auth_cancel');
    whoami = _lib.lookupFunction<_HandleOutErrToStringNative, _HandleOutErrToStringDart>('auth_whoami');
    accountInfo = _lib.lookupFunction<_HandleOutErrToStringNative, _HandleOutErrToStringDart>('auth_account_info');
    registerKey = _lib.lookupFunction<_OneArgToBoolNative, _OneArgToBoolDart>('auth_register_key');
    request = _lib.lookupFunction<_RequestNative, _RequestDart>('auth_request');
    pendingEvents = _lib.lookupFunction<_PendingEventsNative, _PendingEventsDart>('auth_pending_events');
    drainEvents = _lib.lookupFunction<_DrainEventsNative, _DrainEventsDart>('auth_drain_events');
    freeString = _lib.lookupFunction<_FreeStringNative, _FreeStringDart>('auth_free_string');
  }

  static final Map<String, _Native> _cache = {};

  // ignore: unused_field
  final ffi.DynamicLibrary _lib;

  late final _RuntimeInitDart runtimeInit;
  late final _RuntimeGetDart runtimeGet;
  late final _HandleOutErrToBoolDart startLogin;
  late final _SubmitCredentialsDart submitCredentials;
  late final _OneArgToBoolDart submit2faCode;
  late final _OneArgToBoolDart restoreCredentials;
  late final _HandleOutErrToBoolDart logout;
  late final _HandleOutErrToBoolDart cancel;
  late final _HandleOutErrToStringDart whoami;
  late final _HandleOutErrToStringDart accountInfo;
  late final _OneArgToBoolDart registerKey;
  late final _RequestDart request;
  late final _PendingEventsDart pendingEvents;
  late final _DrainEventsDart drainEvents;
  late final _FreeStringDart freeString;
}

/// Finds `libsnapstore_auth.so` next to the running executable (the layout
/// both `flutter run`'s `bundle/` and the packaged snap use — see
/// `linux/CMakeLists.txt`'s `$ORIGIN/lib` rpath), with an env var override
/// for development and a `linux/rust/` fallback for `flutter run` before
/// `scripts/build_rust_backend.sh` has staged the bundle copy.
String _dylibPath() {
  final override = Platform.environment['SNAPSTORE_AUTH_LIB'];
  if (override != null && override.isNotEmpty) return override;

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final candidates = ['$exeDir/lib/libsnapstore_auth.so', '$exeDir/libsnapstore_auth.so', 'linux/rust/libsnapstore_auth.so'];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return candidates.first;
}

ConfdbErrorKind _kindOf(String code, {int? status}) => switch (code) {
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

/// Parses one `{"kind": "...", "detail": "...", "status"?: N}` error JSON
/// payload (the crate's flat wire format; see `rust/src/error.rs`) into a
/// [ConfdbException].
ConfdbException _errorFromJson(String json) {
  try {
    final map = jsonDecode(json) as Map;
    final kind = map['kind'] as String? ?? 'other';
    final detail = map['detail'] as String? ?? json;
    final status = map['status'] as int?;
    final message = status == 401
        ? 'The Snap Store login has expired or was revoked. Sign in again.\n$detail'
        : status == null
        ? detail
        : 'HTTP $status: $detail';
    return ConfdbException(message, kind: _kindOf(kind, status: status));
  } on FormatException {
    return ConfdbException(json, kind: ConfdbErrorKind.other);
  }
}

/// One decoded line from `auth_drain_events`'s `\n`-joined JSON (see
/// `MachineEvent` in `rust/src/state.rs`).
class _Event {
  _Event(this.type, this.data);
  final String type;
  final Map data;
}

List<_Event> _parseEvents(String joined) {
  if (joined.isEmpty) return const [];
  final events = <_Event>[];
  for (final line in joined.split('\n')) {
    if (line.isEmpty) continue;
    final map = jsonDecode(line) as Map;
    events.add(_Event(map['type'] as String? ?? '', map));
  }
  return events;
}

/// A call to run on a background isolate (blocking FFI calls that hit the
/// network — `whoami`/`request` — run via `Isolate.run` so the UI thread
/// isn't stalled for the HTTP timeout; the target `.so` is reopened there,
/// but the underlying Rust statics are process-wide, so it reaches the same
/// already-initialized runtime — see `rust/src/lib.rs`'s `RUNTIME: OnceLock`
/// and `with_runtime`'s null-handle fallback).
class _BlockingCall {
  const _BlockingCall(this.libPath, this.op, this.args);
  final String libPath;
  final String op;
  final List<String?> args;
}

/// `{"kind": "unsupported", "detail": "..."}`, the same wire shape
/// `_errorFromJson` parses, for failures that never reach the Rust side at
/// all (e.g. the `.so` can't be opened — expected in dev/test environments
/// without `scripts/build_rust_backend.sh` having run).
String _localErrorJson(Object error) => jsonEncode({'kind': 'unsupported', 'detail': 'Could not use the Snap Store backend: $error'});

/// `ok: false` means `payload` is the error JSON; never thrown across the
/// isolate boundary directly (records of primitives are safely sendable,
/// arbitrary exception objects are not guaranteed to be).
({bool ok, String payload}) _runBlocking(_BlockingCall call) {
  try {
    final n = _Native(call.libPath);
    final outErr = pkg_ffi.calloc<ffi.Pointer<pkg_ffi.Utf8>>();
    try {
      String errorPayload() {
        final err = outErr.value;
        final message = err.address == 0 ? '{"kind":"other","detail":"unknown error"}' : err.toDartString();
        if (err.address != 0) n.freeString(err);
        return message;
      }

      // `auth_register_key` returns a bool, not a string, so it can't share
      // the pointer-returning branch below.
      if (call.op == 'register_key') {
        final assertion = call.args[0]!.toNativeUtf8();
        final bool ok;
        try {
          ok = n.registerKey(n.runtimeGet(), assertion, outErr);
        } finally {
          pkg_ffi.calloc.free(assertion);
        }
        return ok ? (ok: true, payload: '') : (ok: false, payload: errorPayload());
      }

      final ffi.Pointer<pkg_ffi.Utf8> result;
      switch (call.op) {
        case 'whoami':
          result = n.whoami(n.runtimeGet(), outErr);
        case 'account_info':
          result = n.accountInfo(n.runtimeGet(), outErr);
        case 'request':
          final method = call.args[0]!.toNativeUtf8();
          final path = call.args[1]!.toNativeUtf8();
          final hasBody = call.args[2] != null;
          final hasContentType = call.args[3] != null;
          final body = hasBody ? call.args[2]!.toNativeUtf8() : ffi.nullptr.cast<pkg_ffi.Utf8>();
          final contentType = hasContentType ? call.args[3]!.toNativeUtf8() : ffi.nullptr.cast<pkg_ffi.Utf8>();
          try {
            result = n.request(n.runtimeGet(), method, path, body, contentType, outErr);
          } finally {
            pkg_ffi.calloc.free(method);
            pkg_ffi.calloc.free(path);
            if (hasBody) pkg_ffi.calloc.free(body);
            if (hasContentType) pkg_ffi.calloc.free(contentType);
          }
        default:
          throw ArgumentError('unknown blocking op: ${call.op}');
      }
      if (result.address == 0) {
        return (ok: false, payload: errorPayload());
      }
      final text = result.toDartString();
      n.freeString(result);
      return (ok: true, payload: text);
    } finally {
      pkg_ffi.calloc.free(outErr);
    }
  } on Object catch (e) {
    // Covers `DynamicLibrary.open`/`lookupFunction` failures (missing or
    // mismatched `.so`) as well as anything else unexpected, so callers
    // only ever see [ConfdbException], never a raw FFI error.
    return (ok: false, payload: _localErrorJson(e));
  }
}

/// Real [StoreAuthClient] backed by the vendored `rust/` `snapstore-auth`
/// crate over `dart:ffi`.
///
/// **Process-wide environment limitation**: `auth_runtime_init` (see
/// `rust/src/lib.rs`) is a one-shot singleton — the first call's
/// `store_url`/`login_url` wins for the lifetime of the process, and later
/// calls are no-ops. This means [StoreEnv.production] and
/// [StoreEnv.staging] can't both be used in one run of the app. This class
/// tracks which env first initialized the runtime and throws a
/// [ConfdbException] with [ConfdbErrorKind.unsupported] if asked to use a
/// different one, telling the user to restart instead of silently talking
/// to the wrong store.
class RustAuthClient implements StoreAuthClient {
  RustAuthClient() : _libPath = _dylibPath();

  final String _libPath;
  StoreEnv? _activeEnv;

  /// Whether a previous [login] call left the Rust state machine parked in
  /// `Needs2FACode` (credentials accepted, waiting on a one-time code). The
  /// machine lives on a process-wide runtime handle, not per-call state, so
  /// the *next* [login] call — once the UI has the code — must resume it
  /// with `submit2faCode` only. Reissuing `auth_start_login`/
  /// `auth_submit_credentials` while parked there is an illegal transition
  /// (`rust/src/auth_core.rs` rejects it as "unexpected event in
  /// Needs2FACode").
  bool _awaitingOtp = false;

  /// Tracks whether the machine has reached `Succeeded` (via [login] or
  /// [restoreCredentials]); cleared on [logout].
  ///
  /// A caller can legitimately ask to [login] again while already signed
  /// in — e.g. a UI retry prompted by some *other* call's 401: the
  /// persisted macaroon is known stale (that's exactly why we're here),
  /// so reusing it would just repeat the failure. Reissuing
  /// `auth_start_login` on an already-`Succeeded` machine is also an
  /// illegal transition (`rust/src/auth_core.rs` rejects it as "already
  /// logged in; call logout() first"), so [login] always logs out first
  /// when this is set, discarding the stale macaroon before the fresh
  /// attempt — never short-circuiting to the old credentials.
  String? _activeCredentialsJson;

  _Native get _n {
    try {
      return _Native(_libPath);
    } on Object catch (e) {
      // Covers `DynamicLibrary.open`/`lookupFunction` failures (e.g. the
      // `.so` isn't staged yet — see `scripts/build_rust_backend.sh`), so
      // callers only ever see [ConfdbException].
      throw ConfdbException('Could not use the Snap Store backend: $e', kind: ConfdbErrorKind.unsupported);
    }
  }

  void _ensureInitialized(StoreEnv env) {
    if (_activeEnv != null) {
      if (_activeEnv != env) {
        throw ConfdbException(
          'Already signed in against ${_activeEnv!.label}; restart Confdb Studio '
          'to use ${env.label} instead (the Snap Store backend only supports one '
          'environment per run).',
          kind: ConfdbErrorKind.unsupported,
        );
      }
      return;
    }

    final storeUrlStr = env == StoreEnv.staging ? 'https://${env.host}' : '';
    final storeUrl = storeUrlStr.toNativeUtf8();
    final loginUrl = ''.toNativeUtf8();
    final permissions = ''.toNativeUtf8();
    final storageKey = ''.toNativeUtf8();
    final outErr = pkg_ffi.calloc<ffi.Pointer<pkg_ffi.Utf8>>();
    try {
      final handle = _n.runtimeInit(storeUrl, loginUrl, permissions, storageKey, outErr);
      if (handle.address == 0) {
        final err = outErr.value;
        final message = err.address == 0 ? 'Could not start the Snap Store backend.' : err.toDartString();
        if (err.address != 0) _n.freeString(err);
        throw ConfdbException(message, kind: ConfdbErrorKind.unsupported);
      }
      _activeEnv = env;
    } finally {
      pkg_ffi.calloc.free(storeUrl);
      pkg_ffi.calloc.free(loginUrl);
      pkg_ffi.calloc.free(permissions);
      pkg_ffi.calloc.free(storageKey);
      pkg_ffi.calloc.free(outErr);
    }
  }

  /// Calls a `(handle, out_err) -> bool` native function, raising a
  /// [ConfdbException] on `false`.
  void _call(bool Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr) fn) {
    final outErr = pkg_ffi.calloc<ffi.Pointer<pkg_ffi.Utf8>>();
    try {
      final ok = fn(_n.runtimeGet(), outErr);
      if (!ok) {
        final err = outErr.value;
        if (err.address == 0) {
          throw const ConfdbException('The Snap Store backend reported an unknown error.');
        }
        final json = err.toDartString();
        _n.freeString(err);
        throw _errorFromJson(json);
      }
    } finally {
      pkg_ffi.calloc.free(outErr);
    }
  }

  /// Polls `auth_drain_events` until a terminal event (`Succeeded`,
  /// `Failed`, `Cancelled`) appears, since the crate only exposes polling
  /// (no push/stream FFI primitive — see `rust/src/state.rs`).
  Future<_Event> _awaitTerminalEvent() async {
    while (true) {
      final joined = _n.drainEvents(_n.runtimeGet()).toDartString();
      for (final event in _parseEvents(joined)) {
        switch (event.type) {
          case 'succeeded':
          case 'failed':
          case 'cancelled':
          case 'needs_2fa_code':
            return event;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  StoreAuthSession _sessionFromSucceeded(Map data, StoreAccountInfo account) {
    final credentialsJson = data['credentials_json'] as String? ?? '';
    _activeCredentialsJson = credentialsJson;
    return StoreAuthSession(account: account, credentialsJson: credentialsJson);
  }

  @override
  Future<StoreAuthSession> login({required StoreEnv env, required String email, required String password, String? otp}) async {
    _ensureInitialized(env);

    _Event event;
    if (_awaitingOtp) {
      // Resume the parked machine with just the code instead of restarting
      // the whole login (see [_awaitingOtp]'s doc comment).
      if (otp == null || otp.isEmpty) {
        throw const ConfdbException('This account needs a two-factor authentication code.', kind: ConfdbErrorKind.twoFactorRequired);
      }
      event = await _submitOtp(otp);
    } else {
      // A fresh attempt. Discard any backlog left over from a flow the UI
      // abandoned without [cancelLogin] (e.g. the dialog was closed while
      // parked waiting on a 2FA code) — otherwise a stale buffered event
      // from that abandoned attempt could be misread as this attempt's
      // outcome by [_awaitTerminalEvent] below.
      _n.freeString(_n.drainEvents(_n.runtimeGet()));

      if (_activeCredentialsJson != null) {
        // Already `Succeeded` (see [_activeCredentialsJson]'s doc comment):
        // log out first so the fresh credentials actually get used, rather
        // than reissuing `auth_start_login` straight into Rust's "already
        // logged in" guard, or silently reusing a macaroon we know is bad.
        _activeCredentialsJson = null;
        _call((h, e) => _n.logout(h, e));
      }

      _call((h, e) => _n.startLogin(h, e));

      final emailPtr = email.toNativeUtf8();
      final passwordPtr = password.toNativeUtf8();
      try {
        _call((h, e) => _n.submitCredentials(h, emailPtr, passwordPtr, e));
      } finally {
        pkg_ffi.calloc.free(emailPtr);
        pkg_ffi.calloc.free(passwordPtr);
      }

      event = await _awaitTerminalEvent();

      if (event.type == 'needs_2fa_code') {
        if (otp == null || otp.isEmpty) {
          _awaitingOtp = true;
          throw const ConfdbException('This account needs a two-factor authentication code.', kind: ConfdbErrorKind.twoFactorRequired);
        }
        event = await _submitOtp(otp);
      }
    }

    if (event.type == 'needs_2fa_code') {
      // Wrong/expired code: the machine is parked at Needs2FACode again,
      // ready for another `submit2faCode` resume.
      _awaitingOtp = true;
      throw const ConfdbException('That code wasn’t accepted. Try again.', kind: ConfdbErrorKind.twoFactorRequired);
    }
    _awaitingOtp = false;

    if (event.type == 'failed') {
      final error = event.data['error'];
      throw _errorFromJson(jsonEncode(error));
    }
    if (event.type == 'cancelled') {
      throw const ConfdbException('The sign-in attempt was cancelled.', kind: ConfdbErrorKind.other);
    }
    if (event.type != 'succeeded') {
      throw ConfdbException('Unexpected sign-in state: ${event.type}');
    }

    final account = await whoami();
    return _sessionFromSucceeded(event.data, account);
  }

  /// Submits a one-time code to the already-parked `Needs2FACode` state and
  /// waits for the next terminal event.
  Future<_Event> _submitOtp(String otp) async {
    final otpPtr = otp.toNativeUtf8();
    try {
      _call((h, e) => _n.submit2faCode(h, otpPtr, e));
    } finally {
      pkg_ffi.calloc.free(otpPtr);
    }
    return _awaitTerminalEvent();
  }

  @override
  Future<void> cancelLogin() async {
    if (!_awaitingOtp) return; // nothing parked mid-flow to abandon
    _awaitingOtp = false;
    try {
      // Only reachable while parked at `Needs2FACode` (see the guard
      // above): valid there, resets the machine to `Idle`. Sending it
      // while `Succeeded` would instead tear down the runtime's driver
      // loop, so this must never fire once [_activeCredentialsJson] is set.
      _call((h, e) => _n.cancel(h, e));
    } on ConfdbException {
      // Best-effort: whatever state the machine ends up in, the next
      // [login] call starts a fresh attempt and flushes any stray events.
    }
  }

  @override
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson}) async {
    _ensureInitialized(env);

    final jsonPtr = credentialsJson.toNativeUtf8();
    try {
      _call((h, e) => _n.restoreCredentials(h, jsonPtr, e));
    } finally {
      pkg_ffi.calloc.free(jsonPtr);
    }

    _activeCredentialsJson = credentialsJson;
    final account = await whoami();
    return StoreAuthSession(account: account, credentialsJson: credentialsJson);
  }

  @override
  Future<void> logout() async {
    _activeCredentialsJson = null;
    _awaitingOtp = false;
    if (_activeEnv == null) return;
    _call((h, e) => _n.logout(h, e));
  }

  @override
  Future<StoreAccountInfo> whoami() async {
    final result = await Isolate.run(() => _runBlocking(_BlockingCall(_libPath, 'whoami', const [])));
    if (!result.ok) throw _errorFromJson(result.payload);
    return StoreAccountInfo.fromJson(jsonDecode(result.payload) as Map);
  }

  @override
  Future<Map<String, Object?>> accountInfo() async {
    final result = await Isolate.run(() => _runBlocking(_BlockingCall(_libPath, 'account_info', const [])));
    if (!result.ok) throw _errorFromJson(result.payload);
    return (jsonDecode(result.payload) as Map).cast<String, Object?>();
  }

  @override
  Future<void> registerKey(String accountKeyRequest) async {
    final result = await Isolate.run(() => _runBlocking(_BlockingCall(_libPath, 'register_key', [accountKeyRequest])));
    if (!result.ok) throw _errorFromJson(result.payload);
  }

  @override
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType}) async {
    final result = await Isolate.run(() => _runBlocking(_BlockingCall(_libPath, 'request', [method, path, body, contentType])));
    if (!result.ok) throw _errorFromJson(result.payload);
    final map = jsonDecode(result.payload) as Map;
    return StoreApiResponse(status: map['status'] as int? ?? 0, body: map['body'] as String? ?? '');
  }
}
