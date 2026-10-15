import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../domain/values.dart';

/// A value edited in the Data explorer but not applied yet.
@immutable
class StagedValue {
  const StagedValue({
    required this.view,
    required this.key,
    required this.storagePath,
    required this.node,
    required this.before,
    required this.value,
    this.secret = false,
    this.fromChange,
    this.rejection,
    this.rejectedBy,
  });

  final ViewRef view;
  final String key;
  final String storagePath;
  final StorageNode? node;

  /// Value before the edit (null when unset or unreadable).
  final Object? before;
  final Object? value;

  /// Write-only values are never shown.
  final bool secret;

  /// Change this value came from ("staged from #1842"), or that rejected it.
  final int? fromChange;
  final String? rejection;
  final String? rejectedBy;

  bool get isRejected => rejection != null;

  String get beforeText => secret ? 'hidden' : displayValue(node, before);
  String get afterText => secret ? secretMask : displayValue(node, value);

  /// Unquoted form used by the tray: `band: auto → 5GHz`.
  String get trayText {
    if (secret) {
      return fromChange != null ? '$key: $secretMask (rejected, fix before applying)' : '$key: $secretMask';
    }
    return '$key: ${displayValue(node, before, quoteStrings: false)} → ${displayValue(node, value, quoteStrings: false)}';
  }

  StagedValue copyWith({Object? value, int? fromChange, String? rejection, String? rejectedBy, bool clearRejection = false}) => StagedValue(
    view: view,
    key: key,
    storagePath: storagePath,
    node: node,
    before: before,
    value: value ?? this.value,
    secret: secret,
    fromChange: fromChange ?? this.fromChange,
    rejection: clearRejection ? null : rejection ?? this.rejection,
    rejectedBy: clearRejection ? null : rejectedBy ?? this.rejectedBy,
  );
}

/// Edits staged across views. Applying them is one snapd change per view.
class StagingController extends ChangeNotifier {
  // Map literals keep insertion order, which the tray and review sheet rely on.
  final _byView = <ViewRef, Map<String, StagedValue>>{};

  bool get isEmpty => _byView.isEmpty;
  int get count => _byView.values.fold(0, (n, m) => n + m.length);
  List<ViewRef> get views => _byView.keys.toList();
  List<StagedValue> get all => [for (final m in _byView.values) ...m.values];

  List<StagedValue> forView(ViewRef ref) => _byView[ref]?.values.toList() ?? const [];
  StagedValue? lookup(ViewRef ref, String key) => _byView[ref]?[key];

  void stage(StagedValue v) {
    _byView.putIfAbsent(v.view, () => {})[v.key] = v;
    notifyListeners();
  }

  void unstage(ViewRef ref, String key) {
    final m = _byView[ref];
    if (m == null) return;
    m.remove(key);
    if (m.isEmpty) _byView.remove(ref);
    notifyListeners();
  }

  void clearView(ViewRef ref) {
    if (_byView.remove(ref) != null) notifyListeners();
  }

  void discardAll() {
    _byView.clear();
    notifyListeners();
  }

  /// Keeps the values of a rejected change staged, with the reason attached,
  /// so they can be fixed and applied again.
  void markRejected(ConfdbChange change) {
    final ref = change.view;
    if (ref == null) return;
    final m = _byView[ref];
    if (m == null) return;
    for (final k in m.keys.toList()) {
      m[k] = m[k]!.copyWith(fromChange: change.id, rejection: change.error, rejectedBy: change.rejectedBy);
    }
    notifyListeners();
  }

  /// `sudo snap set <view> k=v …` for everything staged in [ref].
  String commandFor(ViewRef ref) => snapSetCommand(ref, [for (final v in forView(ref)) (v.key, v.value, v.secret)]);
}
