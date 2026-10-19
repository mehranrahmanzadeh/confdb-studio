import 'package:flutter/foundation.dart';

import '../data/confdb_repository.dart';
import '../data/models.dart';
import '../domain/store_sync.dart';

/// The app's Snap Store side: the login and the account's registered
/// schemas, kept for the session so screens don't each ask the network.
class StoreController extends ChangeNotifier {
  StoreController(this._repo);
  final ConfdbRepository _repo;

  StoreSession? _session;
  bool _checking = false;
  List<ConfdbSchema>? _schemas;
  Object? _error;
  bool _loading = false;
  final _busy = <SchemaId>{};

  /// Null until first checked.
  StoreSession? get session => _session;
  bool get signedIn => _session?.signedIn ?? false;
  bool get checking => _checking;

  /// The Store's schemas; null until loaded, or when signed out.
  List<ConfdbSchema>? get schemas => _schemas;

  /// Why the last load failed.
  Object? get error => _error;
  bool get loading => _loading;

  /// Whether a push or install of [id] is running.
  bool busy(SchemaId id) => _busy.contains(id);

  ConfdbSchema? schema(SchemaId id) => _schemas?.where((s) => s.id == id).firstOrNull;

  /// How [device] (null if not acknowledged here) compares with the Store.
  StoreSync compare(SchemaId id, ConfdbSchema? device) => _schemas == null ? StoreSync.unknown : compareWithStore(device, schema(id));

  /// Checks the login, then loads the Store's schemas.
  Future<void> refresh() async {
    if (_checking) return;
    _checking = true;
    notifyListeners();
    try {
      _session = await _repo.storeSession();
      _error = null;
    } catch (e) {
      _session = StoreSession.signedOut(detail: '$e');
    } finally {
      _checking = false;
      notifyListeners();
    }
    await reloadSchemas();
  }

  Future<void> reloadSchemas() async {
    if (!signedIn) {
      _schemas = null;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _schemas = await _repo.listStoreSchemas();
      _error = null;
    } catch (e) {
      _error = e;
      if (e is ConfdbException && e.kind == ConfdbErrorKind.signedOut) {
        _session = StoreSession.signedOut(detail: e.message);
        _schemas = null;
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Throws [ConfdbErrorKind.twoFactorRequired] until [otp] is given, when
  /// the account has a second factor.
  Future<void> login({required String email, required String password, String? otp, StoreEnv env = StoreEnv.production}) async {
    _session = await _repo.storeLogin(email: email, password: password, otp: otp, env: env);
    notifyListeners();
    await reloadSchemas();
  }

  /// Reflects a [ConfdbErrorKind.signedOut] error seen elsewhere (e.g. a 401
  /// registering a signing key) without an extra round-trip to re-check:
  /// the persisted macaroon is known stale, so the rail should offer "Log
  /// in" right away.
  void markSignedOut(String detail) {
    _session = StoreSession.signedOut(detail: detail);
    _schemas = null;
    notifyListeners();
  }

  /// Abandons an in-progress [login] the caller isn't going to finish
  /// (e.g. the dialog's Cancel button was pressed while waiting on a 2FA
  /// code), so the next attempt starts clean.
  Future<void> cancelLogin() => _repo.storeCancelLogin();

  Future<void> logout() async {
    await _repo.storeLogout();
    _session = const StoreSession.signedOut();
    _schemas = null;
    _error = null;
    notifyListeners();
  }

  Future<void> _run(SchemaId id, Future<void> Function() action) async {
    _busy.add(id);
    notifyListeners();
    try {
      await action();
    } finally {
      _busy.remove(id);
      notifyListeners();
    }
    await reloadSchemas();
  }

  /// Registers this device's revision of [id] in the Store.
  Future<void> push(SchemaId id) => _run(id, () => _repo.pushToStore(id));

  /// Acknowledges the Store's revision of [id] on this device.
  Future<void> install(SchemaId id) => _run(id, () => _repo.installFromStore(id));
}
