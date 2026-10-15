import 'package:flutter/widgets.dart';

import '../data/confdb_repository.dart';
import '../data/models.dart';

/// Account IDs are long random strings; this resolves them, once each, to the
/// usernames people know them by, so the UI can show those instead.
class AccountNames extends ChangeNotifier {
  AccountNames(this._repo);
  final ConfdbRepository _repo;

  final _known = <String, AccountInfo?>{};
  final _pending = <String>{};

  /// Not real store accounts: built-in schemas live under `system`.
  static const _reserved = {'system'};

  /// Whether [id] names snapd itself rather than a store account.
  static bool isReserved(String id) => _reserved.contains(id);

  /// The account assertion for [id], once resolved.
  AccountInfo? info(String id) {
    resolve([id]);
    return _known[id];
  }

  /// The username for [id], or [id] until (or unless) it resolves.
  String alias(String id) => info(id)?.alias ?? id;

  /// Whether [id] shows as something else.
  bool hasAlias(String id) => alias(id) != id;

  /// Looks up the ids not seen yet; listeners hear when they arrive.
  void resolve(Iterable<String> ids) {
    for (final id in ids) {
      if (id.isEmpty || _reserved.contains(id) || _known.containsKey(id) || !_pending.add(id)) continue;
      _repo.account(id).then((a) => _known[id] = a, onError: (_) => _known[id] = null).whenComplete(() {
        _pending.remove(id);
        notifyListeners();
      });
    }
  }

  /// [text] with every resolved account ID swapped for its alias, for
  /// sentences and paths shown (not copied or run).
  String aliasIn(String text) {
    var out = text;
    for (final MapEntry(key: id, value: a) in _known.entries) {
      if (a != null && a.alias != id && out.contains(id)) out = out.replaceAll(id, a.alias);
    }
    return out;
  }
}

/// Rebuilds widgets that show aliases when more accounts resolve.
class AccountNamesScope extends InheritedNotifier<AccountNames> {
  const AccountNamesScope({super.key, required AccountNames names, required super.child}) : super(notifier: names);

  static AccountNames? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AccountNamesScope>()?.notifier;
}

extension AccountNamesContext on BuildContext {
  /// The app's [AccountNames]; null outside the app (isolated widget tests).
  AccountNames? get accounts => AccountNamesScope.maybeOf(this);

  /// [text] with account IDs shown as their aliases.
  String aliased(String text) => accounts?.aliasIn(text) ?? text;
}
