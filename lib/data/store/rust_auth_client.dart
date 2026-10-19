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

typedef _RuntimeInitNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<pkg_ffi.Utf8> storeUrl,
      ffi.Pointer<pkg_ffi.Utf8> loginUrl,
      ffi.Pointer<pkg_ffi.Utf8> permissions,
      ffi.Pointer<pkg_ffi.Utf8> storageKey,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );
typedef _RuntimeInitDart =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<pkg_ffi.Utf8> storeUrl,
      ffi.Pointer<pkg_ffi.Utf8> loginUrl,
      ffi.Pointer<pkg_ffi.Utf8> permissions,
      ffi.Pointer<pkg_ffi.Utf8> storageKey,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );

typedef _RuntimeGetNative = ffi.Pointer<ffi.Void> Function();
typedef _RuntimeGetDart = ffi.Pointer<ffi.Void> Function();

typedef _HandleOutErrToBoolNative =
    ffi.Bool Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr);
typedef _HandleOutErrToBoolDart =
    bool Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr);

typedef _SubmitCredentialsNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<pkg_ffi.Utf8> email,
      ffi.Pointer<pkg_ffi.Utf8> password,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );
typedef _SubmitCredentialsDart =
    bool Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<pkg_ffi.Utf8> email,
      ffi.Pointer<pkg_ffi.Utf8> password,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );

typedef _OneArgToBoolNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<pkg_ffi.Utf8> arg,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );
typedef _OneArgToBoolDart =
    bool Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<pkg_ffi.Utf8> arg,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );

typedef _HandleOutErrToStringNative =
    ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void> handle, ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr);
typedef _HandleOutErrToStringDart =
    ffi.Pointer<pkg_ffi.Utf8> Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );

typedef _DrainEventsNative = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void> handle);
typedef _DrainEventsDart = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void> handle);

typedef _PendingEventsNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void> handle);
typedef _PendingEventsDart = int Function(ffi.Pointer<ffi.Void> handle);

typedef _RequestNative =
    ffi.Pointer<pkg_ffi.Utf8> Function(
      ffi.Pointer<ffi.Void> handle,
      ffi.Pointer<pkg_ffi.Utf8> method,
      ffi.Pointer<pkg_ffi.Utf8> path,
      ffi.Pointer<pkg_ffi.Utf8> body,
      ffi.Pointer<pkg_ffi.Utf8> contentType,
      ffi.Pointer<ffi.Pointer<pkg_ffi.Utf8>> outErr,
    );
typedef _RequestDart =
    ffi.Pointer<pkg_ffi.Utf8> Function(
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
    submitCredentials = _lib.lookupFunction<_SubmitCredentialsNative, _SubmitCredentialsDart>(
      'auth_submit_credentials',
    );
    submit2faCode = _lib.lookupFunction<_OneArgToBoolNative, _OneArgToBoolDart>('auth_submit_2fa_code');
    restoreCredentials = _lib.lookupFunction<_OneArgToBoolNative, _OneArgToBoolDart>('auth_restore_credentials');
    logout = _lib.lookupFunction<_HandleOutErrToBoolNative, _HandleOutErrToBoolDart>('auth_logout');
    cancel = _lib.lookupFunction<_HandleOutErrToBoolNative, _HandleOutErrToBoolDart>('auth_cancel');
    whoami = _lib.lookupFunction<_HandleOutErrToStringNative, _HandleOutErrToStringDart>('auth_whoami');
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
  final candidates = [
    '$exeDir/lib/libsnapstore_auth.so',
    '$exeDir/libsnapstore_auth.so',
    'linux/rust/libsnapstore_auth.so',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return candidates.first;
}

ConfdbErrorKind _kindOf(String code) => switch (code) {
  'network' => ConfdbErrorKind.offline,
  'http' => ConfdbErrorKind.other,
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
    final status = map['status'];
    final message = status == null ? detail : 'HTTP $status: $detail';
    return ConfdbException(message, kind: _kindOf(kind));
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
      final ffi.Pointer<pkg_ffi.Utf8> result;
      switch (call.op) {
        case 'whoami':
          result = n.whoami(n.runtimeGet(), outErr);
        case 'request':
          final method = call.args[0]!.toNativeUtf8();
          final path = call.args[1]!.toNativeUtf8();
          final hasBody = call.args[2] != null;
          final hasContentType = call.args[3] != null;
          final body = hasBody ? call.args[2]!.toNativeUtf8() : ffi.nullptr.cast<pkg_ffi.Utf8>();
          final contentType = hasContentType
              ? call.args[3]!.toNativeUtf8()
              : ffi.nullptr.cast<pkg_ffi.Utf8>();
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
        final err = outErr.value;
        final message = err.address == 0 ? '{"kind":"other","detail":"unknown error"}' : err.toDartString();
        if (err.address != 0) n.freeString(err);
        return (ok: false, payload: message);
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

  StoreAuthSession _sessionFromSucceeded(Map data, StoreAccountInfo account) =>
      StoreAuthSession(account: account, credentialsJson: data['credentials_json'] as String? ?? '');

  @override
  Future<StoreAuthSession> login({
    required StoreEnv env,
    required String email,
    required String password,
    String? otp,
  }) async {
    _ensureInitialized(env);

    _call((h, e) => _n.startLogin(h, e));

    final emailPtr = email.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();
    try {
      _call((h, e) => _n.submitCredentials(h, emailPtr, passwordPtr, e));
    } finally {
      pkg_ffi.calloc.free(emailPtr);
      pkg_ffi.calloc.free(passwordPtr);
    }

    var event = await _awaitTerminalEvent();

    if (event.type == 'needs_2fa_code') {
      if (otp == null || otp.isEmpty) {
        throw const ConfdbException(
          'This account needs a two-factor authentication code.',
          kind: ConfdbErrorKind.twoFactorRequired,
        );
      }
      final otpPtr = otp.toNativeUtf8();
      try {
        _call((h, e) => _n.submit2faCode(h, otpPtr, e));
      } finally {
        pkg_ffi.calloc.free(otpPtr);
      }
      event = await _awaitTerminalEvent();
    }

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

  @override
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson}) async {
    _ensureInitialized(env);

    final jsonPtr = credentialsJson.toNativeUtf8();
    try {
      _call((h, e) => _n.restoreCredentials(h, jsonPtr, e));
    } finally {
      pkg_ffi.calloc.free(jsonPtr);
    }

    final account = await whoami();
    return StoreAuthSession(account: account, credentialsJson: credentialsJson);
  }

  @override
  Future<void> logout() async {
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
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType}) async {
    final result = await Isolate.run(
      () => _runBlocking(_BlockingCall(_libPath, 'request', [method, path, body, contentType])),
    );
    if (!result.ok) throw _errorFromJson(result.payload);
    final map = jsonDecode(result.payload) as Map;
    return StoreApiResponse(status: map['status'] as int? ?? 0, body: map['body'] as String? ?? '');
  }
}
