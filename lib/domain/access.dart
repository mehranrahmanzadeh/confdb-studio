// Who can reach what: hooks a write will run, and the "why can't this snap
// see a value?" diagnosis.
import '../data/models.dart';
import 'analysis.dart';

class PlannedHook {
  const PlannedHook({required this.snap, required this.hook, required this.description, required this.role});
  final String snap;
  final String hook;
  final String description;
  final PlugRole role;
}

/// Connected plugs whose view (in [schema]) touches any of [storagePaths].
List<ConfdbPlug> _plugsTouching(ConfdbSchema schema, List<SnapInfo> snaps, Set<String> storagePaths, PlugRole role) => [
  for (final s in snaps)
    for (final p in s.plugs)
      if (p.role == role &&
          p.state.isConnected &&
          p.view.schemaId == schema.id &&
          (schema.view(p.view.view)?.rules.any((r) => storagePaths.any((sp) => ruleExposes(r, sp))) ?? false))
        p,
];

/// Hooks snapd runs, in order, when values at [storagePaths] are written.
List<PlannedHook> planWriteHooks(ConfdbSchema schema, List<SnapInfo> snaps, Set<String> storagePaths) {
  final custodians = _plugsTouching(schema, snaps, storagePaths, PlugRole.custodian);
  final observers = _plugsTouching(schema, snaps, storagePaths, PlugRole.observer);
  final what = switch (storagePaths.length) {
    1 => 'the value',
    2 => 'both values',
    _ => 'all ${storagePaths.length} values',
  };
  return [
    for (final p in custodians)
      PlannedHook(
        snap: p.snap,
        hook: 'change-view-${p.plug}',
        role: PlugRole.custodian,
        description: 'Custodian validates $what; it can reject the change, which rolls everything back.',
      ),
    for (final p in custodians)
      PlannedHook(
        snap: p.snap,
        hook: 'save-view-${p.plug}',
        role: PlugRole.custodian,
        description: 'Custodian persists the ${storagePaths.length == 1 ? 'value' : 'values'} once validation passes.',
      ),
    for (final p in observers)
      PlannedHook(
        snap: p.snap,
        hook: 'observe-view-${p.plug}',
        role: PlugRole.observer,
        description: 'Observer is notified after commit; it can’t block the change.',
      ),
  ];
}

/// Connected custodian of a view, if any.
ConfdbPlug? custodianOf(ViewRef ref, List<SnapInfo> snaps) {
  for (final s in snaps) {
    for (final p in s.plugs) {
      if (p.view == ref && p.role == PlugRole.custodian) return p;
    }
  }
  return null;
}

// ------------------------------------------------------------- diagnosis

enum CheckState { passed, failed, skipped }

class AccessCheck {
  const AccessCheck({required this.title, required this.state, required this.text, this.fixConnect});
  final String title;
  final CheckState state;

  /// Text with `backticked` identifiers.
  final String text;

  /// Set when connecting this plug would fix the failure.
  final ConfdbPlug? fixConnect;
}

class AccessDiagnosis {
  const AccessDiagnosis({required this.snap, required this.storagePath, required this.checks, required this.reason});
  final String snap;
  final String storagePath;
  final List<AccessCheck> checks;

  /// Short reason for the first failure, e.g. "plug not connected".
  final String? reason;

  bool get ok => checks.every((c) => c.state == CheckState.passed);
  int? get failedStep {
    final i = checks.indexWhere((c) => c.state == CheckState.failed);
    return i < 0 ? null : i + 1;
  }
}

/// Walks the four conditions a snap needs to read [storagePath]:
/// plug connected, view exposes the path, access allows read, ephemeral load.
Future<AccessDiagnosis> diagnoseAccess({
  required SnapInfo snap,
  required String storagePath,
  required List<ConfdbSchema> schemas,
  required Future<ViewSnapshot> Function(ViewRef) readView,
}) async {
  const titles = ['Plug connected', 'View exposes path', 'Access allows read', 'Ephemeral load succeeded'];
  final checks = <AccessCheck>[];
  String? reason;

  AccessDiagnosis stop(int failedIndex, String why) {
    reason = why;
    for (var i = checks.length; i < titles.length; i++) {
      checks.add(AccessCheck(title: titles[i], state: CheckState.skipped, text: 'Stopped at step ${failedIndex + 1}.'));
    }
    return AccessDiagnosis(snap: snap.name, storagePath: storagePath, checks: checks, reason: reason);
  }

  ConfdbSchema? schemaFor(ConfdbPlug p) => schemas.where((s) => s.id == p.view.schemaId).firstOrNull;
  ViewRule? ruleFor(ConfdbPlug p) => schemaFor(p)?.view(p.view.view)?.rules.where((r) => ruleExposes(r, storagePath)).firstOrNull;

  if (snap.plugs.isEmpty) {
    checks.add(AccessCheck(title: titles[0], state: CheckState.failed, text: '`${snap.name}` has no confdb plugs.'));
    return stop(0, 'no confdb plug');
  }

  // 1. A plug whose view exposes the path should be connected.
  final exposing = snap.plugs.where((p) => ruleFor(p) != null).toList();
  final candidates = exposing.isNotEmpty ? exposing : snap.plugs;
  final connected = candidates.where((p) => p.state.isConnected).firstOrNull;
  if (connected == null) {
    final p = candidates.first;
    checks.add(AccessCheck(title: titles[0], state: CheckState.failed, text: '`${p.id}` is not connected.', fixConnect: p));
    return stop(0, 'plug not connected');
  }
  checks.add(AccessCheck(title: titles[0], state: CheckState.passed, text: '`${connected.id}` is connected.'));

  // 2. The view maps a request path to the storage path.
  final rule = ruleFor(connected);
  if (rule == null) {
    checks.add(AccessCheck(title: titles[1], state: CheckState.failed, text: 'No view of `${snap.name}` exposes `$storagePath`.'));
    return stop(1, 'path not exposed');
  }
  checks.add(
    AccessCheck(title: titles[1], state: CheckState.passed, text: '`${connected.view.view}` maps `${rule.request}` → `${rule.storage}`.'),
  );

  // 3. The rule must allow reading.
  if (!rule.access.canRead) {
    checks.add(AccessCheck(title: titles[2], state: CheckState.failed, text: 'Rule access is ${rule.access.label}; reads are refused.'));
    return stop(2, 'access is write-only');
  }
  checks.add(AccessCheck(title: titles[2], state: CheckState.passed, text: 'Rule access is ${rule.access.label}.'));

  // 4. Ephemeral values are loaded by the custodian's load-view hook.
  final node = resolveStoragePath(schemaFor(connected)!.storage, storagePath);
  if (node == null || !node.ephemeral) {
    checks.add(AccessCheck(title: titles[3], state: CheckState.passed, text: '`$storagePath` is stored, not ephemeral; no load needed.'));
  } else {
    final snapshot = await readView(connected.view);
    final failure = snapshot.loadFailure;
    final entryError = snapshot.entries.where((e) => e.rule.storage == storagePath).firstOrNull?.loadError;
    if (failure != null || entryError != null) {
      checks.add(
        AccessCheck(
          title: titles[3],
          state: CheckState.failed,
          text: failure != null ? '`${failure.hook}` on `${failure.snap}` failed: ${failure.message}' : entryError!,
        ),
      );
      return stop(3, 'load-view hook failed');
    }
    checks.add(AccessCheck(title: titles[3], state: CheckState.passed, text: '`$storagePath` loaded by the custodian.'));
  }
  return AccessDiagnosis(snap: snap.name, storagePath: storagePath, checks: checks, reason: null);
}
