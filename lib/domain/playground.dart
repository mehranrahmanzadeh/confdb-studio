// Simulates how snapd resolves `snapctl get/set --view` through a view of a
// draft, entirely in the app: nothing is read from or written to snapd, and no
// hooks run. Follows snapd's order of checks and uses its error messages
// (overlord/hookstate/ctlcmd, overlord/confdbstate, confdb/confdb.go).
import 'dart:convert';

import '../data/models.dart';
import 'paths.dart';
import 'analysis.dart';
import 'values.dart';

enum SimState { passed, failed, warning, skipped, info }

class SimStep {
  const SimStep({
    required this.title,
    required this.state,
    required this.statusLabel,
    required this.text,
    this.code,
    this.fixConnect,
    this.missingPlug = false,
  });
  final String title;
  final SimState state;
  final String statusLabel;
  final String? code;

  /// Text with `backticked` identifiers.
  final String text;
  final ConfdbPlug? fixConnect;

  /// The snap declares no plug for the view: it has to add one.
  final bool missingPlug;
}

class SimResult {
  const SimResult({required this.steps, required this.summary});
  final List<SimStep> steps;

  /// e.g. "Get `ssid` through `acme/network/wifi-admin` as `net-manager`".
  final String summary;

  bool get allowed => steps.every((s) => s.state != SimState.failed);

  /// Allowed, but only once something is fixed (e.g. a plug is connected).
  bool get hasWarnings => steps.any((s) => s.state == SimState.warning);
  int? get deniedAt {
    final i = steps.indexWhere((s) => s.state == SimState.failed);
    return i < 0 ? null : i + 1;
  }
}

class SimRequest {
  const SimRequest({
    required this.draft,
    required this.view,
    required this.path,
    required this.isSet,
    required this.snap,
    this.value,
    this.asRoot = false,
  });
  final ConfdbSchema draft;
  final String view;
  final String path;
  final bool isSet;
  final String? value;
  final SnapInfo snap;

  /// snapctl runs as root in hooks and services, and snapd then grants admin
  /// access (secrets included). Apps started by a user get unprivileged access.
  final bool asRoot;

  ViewRef get ref => draft.id.view(view);
}

/// `snapctl get --view :wifi-admin ssid`, as the snap would run it.
String snapctlCommand(SimRequest r) {
  // Without a plug for the view, the name the add-plug guide suggests.
  final name = r.snap.plugs.where((p) => p.view == r.ref).firstOrNull?.plug ?? r.view;
  if (r.isSet) return "snapctl set --view :$name ${r.path}=${shellQuote(r.value ?? '')}";
  return 'snapctl get --view :$name ${r.path}';
}

/// One rule a request matched, with its storage path filled in from the
/// request (placeholders the request doesn't reach stay open).
class _Match {
  _Match(this.rule, this.bindings, this.suffix, this.storage);
  final ViewRule rule;
  final Map<String, String> bindings;
  final List<PathSegment> suffix;
  final String storage;
}

SimResult simulate(SimRequest r, {required List<SnapInfo> snaps}) {
  final op = r.isSet ? 'set' : 'get';
  final viewId = r.ref.path;
  final quoted = r.path.isEmpty ? '' : ' "${r.path}"';
  final summary = '${r.isSet ? 'Set' : 'Get'} `${r.path.isEmpty ? '(whole view)' : r.path}` through `$viewId` as `${r.snap.name}`';
  final titles = r.isSet
      ? ['Plug', 'Rule match', 'Storage and value', 'Custodian and hooks']
      : ['Plug', 'Custodian and hooks', 'Rule match', 'Storage and visibility'];
  final steps = <SimStep>[];

  SimResult stop() {
    for (var i = steps.length; i < titles.length; i++) {
      steps.add(SimStep(title: titles[i], state: SimState.skipped, statusLabel: 'Not reached', text: 'Not reached.'));
    }
    return SimResult(steps: steps, summary: summary);
  }

  SimStep fail(String title, String error, String text) =>
      SimStep(title: title, state: SimState.failed, statusLabel: 'Failed', code: error, text: text);

  // ---- Plug: snapctl names one of the snap's confdb plugs (`:plug`).
  final plug = r.snap.plugs.where((p) => p.view == r.ref).firstOrNull;
  final access = r.asRoot
      ? 'Runs as root (a hook or service), so snapd grants admin access.'
      : 'Runs as a user (an app started by a user), so snapd grants unprivileged access: secrets can’t be read.';
  if (plug == null) {
    steps.add(
      SimStep(
        title: titles[0],
        state: SimState.failed,
        statusLabel: 'No plug',
        code: 'no plug for $viewId',
        text: '`${r.snap.name}` doesn’t have a plug for this view, so it can’t reach it through snapctl.',
        missingPlug: true,
      ),
    );
    return stop();
  }
  steps.add(
    plug.state.isConnected
        ? SimStep(
            title: titles[0],
            state: SimState.passed,
            statusLabel: 'Passed',
            code: 'snapctl $op --view :${plug.plug}',
            text: '`${r.snap.name}:${plug.plug}` is connected (${plug.role.label.toLowerCase()}). $access',
          )
        : SimStep(
            title: titles[0],
            state: SimState.warning,
            statusLabel: 'Not connected yet',
            code: 'cannot access confdb through unconnected plug :${plug.plug}',
            text:
                'snapd refuses requests through `${r.snap.name}:${plug.plug}` until it’s connected, with the error above. '
                'The steps below assume it’s connected. $access',
            fixConnect: plug,
          ),
  );

  final view = r.draft.view(r.view);
  final custodians = [
    for (final s in snaps)
      for (final p in s.plugs)
        if (p.view == r.ref && p.role == PlugRole.custodian && (p.state.isConnected || (s.name == r.snap.name && p == plug))) (s, p),
  ]..sort((a, b) => a.$1.name.compareTo(b.$1.name));
  bool declares(SnapInfo s, String hook) => s.hooks.any((h) => h.name == hook);
  final hooksUnknown = custodians.any((c) => !c.$1.hooksKnown);

  // ---- Rule match: every rule whose request the path is (a prefix of),
  // keeping only rules that allow the operation.
  List<_Match> matchRules() => [
    for (final rule in view?.rules ?? const <ViewRule>[])
      if (matchRequest(rule.request, r.path) case final m?) _Match(rule, m.bindings, m.suffix, fillPath(rule.storage, m.bindings)),
  ];
  final all = matchRules();
  final matches = [
    for (final m in all)
      if (r.isSet ? m.rule.access.canWrite : m.rule.access.canRead) m,
  ];
  SimStep ruleStep() {
    if (matches.isEmpty) {
      final skipped = all.map((m) => '`${m.rule.request}` (${m.rule.access.label})').join(', ');
      return fail(
        titles[r.isSet ? 1 : 2],
        'cannot $op$quoted through $viewId: no matching rule',
        all.isEmpty
            ? 'No rule’s request is `${r.path}` or starts with it. Requests can be shorter than a rule’s (a prefix), never longer.'
            : 'Rules match, but none allows $op: $skipped.',
      );
    }
    return SimStep(
      title: titles[r.isSet ? 1 : 2],
      state: SimState.passed,
      statusLabel: matches.length == 1 ? 'Passed' : 'Passed · ${matches.length} rules',
      code: [for (final m in matches) '${fillPath(m.rule.request, m.bindings)} → ${m.storage}'].join('\n'),
      text: [
        if (matches.length > 1) 'snapd uses every matching rule and merges the results.',
        if (matches.any((m) => m.suffix.isNotEmpty)) 'The request is a prefix of the rule, so it covers everything below it.',
        if (matches.any((m) => m.bindings.isNotEmpty))
          'Placeholders: ${{for (final m in matches) ...m.bindings.entries.map((e) => '`{${e.key}}` = `${e.value}`')}.join(', ')}.',
        if (matches.any((m) => filterParams(m.rule.storage).isNotEmpty))
          'Field filters (${{for (final m in matches) ...filterParams(m.rule.storage)}.map((p) => '`$p`').join(', ')}) apply only when the caller passes `--with`; they aren’t simulated.',
        if (all.length > matches.length)
          'Skipped for $op: ${all.where((m) => !matches.contains(m)).map((m) => '`${m.rule.request}` (${m.rule.access.label})').join(', ')}.',
      ].where((t) => t.isNotEmpty).join(' ').ifEmpty('Rule matched.'),
    );
  }

  // Storage definitions in the draft for each match.
  StorageNode? nodeOf(_Match m) => resolveStoragePath(r.draft.storage, m.storage);
  final missing = [
    for (final m in matches)
      if (nodeOf(m) == null) m,
  ];
  SimStep missingStep(int i) => fail(
    titles[i],
    missing.map((m) => m.storage).join('\n'),
    '${missing.length == 1 ? 'This storage path does' : 'These storage paths do'} not exist in the draft’s storage.',
  );
  bool touchesEphemeral() => matches.any((m) {
    final n = nodeOf(m);
    return n != null &&
        (n.ephemeral || _ancestors(r.draft.storage, m.storage).any((a) => a.ephemeral) || _descendants(n).any((d) => d.ephemeral));
  });

  // ---- Custodian and hooks.
  SimStep? hookStep(int i) {
    final verb = r.isSet ? 'write' : 'read';
    if (custodians.isEmpty) {
      return fail(
        titles[i],
        'cannot $verb confdb view $viewId: no custodian snap connected',
        'snapd needs a connected custodian for this view for every ${r.isSet ? 'set' : 'get'}, even of stored values.',
      );
    }
    final hooks = <String>[];
    final prefixes = r.isSet ? ['change-view-', 'save-view-'] : ['load-view-', 'query-view-'];
    for (final prefix in prefixes) {
      for (final (s, p) in custodians) {
        if (declares(s, '$prefix${p.plug}')) hooks.add('`$prefix${p.plug}` on `${s.name}`');
      }
    }
    final ephemeralHook = r.isSet ? 'save-view-' : 'load-view-';
    if (touchesEphemeral() && !hooksUnknown && !custodians.any((c) => declares(c.$1, '$ephemeralHook${c.$2.plug}'))) {
      return fail(
        titles[i],
        r.isSet
            ? 'cannot write confdb view $viewId: write might change ephemeral data but no custodians has a save-view hook'
            : 'cannot schedule tasks to read view $viewId: read might cover ephemeral data but no custodian has a load-view hook',
        'The request reaches ephemeral data, and no custodian (${custodians.map((c) => '`${c.$1.name}`').join(', ')}) has a `$ephemeralHook…` hook for this view.',
      );
    }
    final observers = r.isSet ? _observers(r, snaps, matches.map((m) => m.storage)) : const <String>[];
    final names = custodians.map((c) => '`${c.$1.name}`').join(', ');
    return SimStep(
      title: titles[i],
      state: hooksUnknown ? SimState.warning : SimState.info,
      statusLabel: 'Would run: ${hooks.length + observers.length} ${hooks.length + observers.length == 1 ? 'hook' : 'hooks'}',
      code: [...hooks, ...observers].map((h) => h.replaceAll('`', '')).join('\n'),
      text: [
        'Custodian${custodians.length == 1 ? '' : 's'}: $names.',
        if (hooks.isEmpty) 'No custodian declares a ${prefixes.map((p) => '`$p…`').join(' or ')} hook for this view, so none run.',
        if (r.isSet && observers.isNotEmpty) 'Then observers are notified (their failures are ignored). The calling snap isn’t notified.',
        if (hooksUnknown) 'Couldn’t read the hooks some custodians declare, so this list may be incomplete.',
      ].join(' '),
    );
  }

  if (!r.isSet) {
    final h = hookStep(1)!;
    steps.add(h);
    if (h.state == SimState.failed) return stop();
    final rs = ruleStep();
    steps.add(rs);
    if (rs.state == SimState.failed) return stop();
    if (missing.isNotEmpty) {
      steps.add(missingStep(3));
      return stop();
    }
    // Visibility: unprivileged reads lose secrets; a request left with nothing
    // is "unauthorized access".
    final hidden = <_Match>[], partly = <_Match>[];
    for (final m in matches) {
      final n = nodeOf(m)!;
      if (n.secret || _ancestors(r.draft.storage, m.storage).any((a) => a.secret)) {
        hidden.add(m);
      } else if (_descendants(n).any((d) => d.secret)) {
        partly.add(m);
      }
    }
    if (!r.asRoot && hidden.length == matches.length) {
      steps.add(
        fail(
          titles[3],
          'cannot get$quoted through $viewId: unauthorized access',
          '${hidden.map((m) => '`${m.storage}`').join(', ')} ${hidden.length == 1 ? 'is' : 'are'} secret, and an app run by a user only gets unprivileged access. '
              'Run it from a hook or service (as root) to read it.',
        ),
      );
      return stop();
    }
    steps.add(
      SimStep(
        title: titles[3],
        state: !r.asRoot && (hidden.isNotEmpty || partly.isNotEmpty) ? SimState.warning : SimState.passed,
        statusLabel: !r.asRoot && (hidden.isNotEmpty || partly.isNotEmpty) ? 'Secrets left out' : 'Passed',
        code: [for (final m in matches) '${m.storage}  ·  ${nodeOf(m)!.typeLabel}'].join('\n'),
        text: [
          if (!r.asRoot && hidden.isNotEmpty) 'Left out as secret: ${hidden.map((m) => '`${m.storage}`').join(', ')}.',
          if (!r.asRoot && partly.isNotEmpty) 'Secret keys inside ${partly.map((m) => '`${m.storage}`').join(', ')} are left out.',
          if (r.asRoot && [...hidden, ...partly].isNotEmpty) 'Includes secrets: admin access reads them.',
          if (matches.any((m) => nodeOf(m)!.ephemeral)) 'Ephemeral; loaded by the custodian’s load-view hook.',
          'snapd returns “no data” if nothing is stored there.',
        ].join(' '),
      ),
    );
    return SimResult(steps: steps, summary: summary);
  }

  // ---- Set.
  final rs = ruleStep();
  steps.add(rs);
  if (rs.state == SimState.failed) return stop();
  if (missing.isNotEmpty) {
    steps.add(missingStep(2));
    return stop();
  }
  final valueText = r.value ?? '';
  Object? value;
  try {
    value = jsonDecode(valueText);
  } on FormatException {
    value = valueText; // snapctl sets non-JSON input as a string
  }
  final problem = _checkSet(r.draft.storage, matches, value, valueText);
  if (problem != null) {
    steps.add(fail(titles[2], problem.$1, problem.$2));
    return stop();
  }
  final secret = matches.any((m) {
    final n = nodeOf(m)!;
    return n.secret || _ancestors(r.draft.storage, m.storage).any((a) => a.secret) || _descendants(n).any((d) => d.secret);
  });
  steps.add(
    SimStep(
      title: titles[2],
      state: SimState.passed,
      statusLabel: 'Passed',
      code: [for (final m in matches) '${m.storage}  ·  ${nodeOf(m)!.typeLabel}'].join('\n'),
      text: [
        'Matches the draft’s storage schema.',
        if (secret && !r.asRoot) 'Secret: writing is allowed, but this snap can’t read it back unless it runs as root.',
      ].join(' '),
    ),
  );
  final h = hookStep(3)!;
  steps.add(h);
  return h.state == SimState.failed ? stop() : SimResult(steps: steps, summary: summary);
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Nodes along [path] above its last segment.
Iterable<StorageNode> _ancestors(StorageNode root, String path) sync* {
  final segs = tryParsePath(path) ?? const <PathSegment>[];
  for (var i = 1; i < segs.length; i++) {
    final n = resolveStoragePath(root, joinPath(segs.take(i)));
    if (n != null) yield n;
  }
}

/// Every definition below [n]: children and map values / array elements.
Iterable<StorageNode> _descendants(StorageNode n) sync* {
  for (final (_, _, d) in n.walk()) {
    yield d;
  }
  final e = n.kind == StorageKind.array ? n.element : null;
  if (e != null) {
    yield e;
    yield* _descendants(e);
  }
}

/// Snaps other than the caller with a connected plug whose view exposes any
/// of [storage], as `observe-view-<plug>` hooks they declare.
List<String> _observers(SimRequest r, List<SnapInfo> snaps, Iterable<String> storage) => [
  for (final s in [...snaps]..sort((a, b) => a.name.compareTo(b.name)))
    if (s.name != r.snap.name)
      for (final p in s.plugs)
        if (p.view.schemaId == r.draft.id &&
            p.state.isConnected &&
            s.hooks.any((h) => h.name == 'observe-view-${p.plug}') &&
            (r.draft
                    .view(p.view.view)
                    ?.rules
                    .any((rule) => storage.any((st) => ruleCovers(rule.storage, st) || ruleCovers(st, rule.storage))) ??
                false))
          '`observe-view-${p.plug}` on `${s.name}`',
];

/// Checks a set's value the way snapd does: the request's unmatched rule
/// suffix is walked through the value, every part of the value must be used,
/// containers can't be empty, and what lands in storage must fit the schema.
/// Returns (error, explanation), or null when it passes.
(String, String)? _checkSet(StorageNode root, List<_Match> matches, Object? value, String text) {
  if ((value is Map && value.isEmpty) || (value is List && value.isEmpty)) {
    return ('cannot set empty container: must contain at least one scalar', 'Set a value with at least one scalar in it.');
  }
  final used = <String>{};
  for (final m in matches) {
    // Walk the suffix through the value: keys pick sub-values, placeholders
    // spread over the value's keys or indexes.
    var level = <(List<String>, Object?, List<PathSegment>)>[(const [], value, const [])];
    for (final seg in m.suffix) {
      final next = <(List<String>, Object?, List<PathSegment>)>[];
      for (final (at, v, path) in level) {
        if (seg.kind == SegmentKind.key && v is Map && v.containsKey(seg.name)) {
          next.add(([...at, seg.name], v[seg.name], [...path, seg]));
        } else if (seg.kind == SegmentKind.keyPlaceholder && v is Map) {
          for (final e in v.entries) {
            next.add(([...at, '${e.key}'], e.value, [...path, PathSegment(SegmentKind.key, '${e.key}')]));
          }
        } else if (seg.kind == SegmentKind.indexPlaceholder && v is List) {
          for (var i = 0; i < v.length; i++) {
            next.add(([...at, '$i'], v[i], [...path, PathSegment(SegmentKind.listIndex, '$i')]));
          }
        }
      }
      level = next;
    }
    for (final (at, v, path) in level) {
      used.add(at.join('\u0000'));
      final storagePath = path.isEmpty ? m.storage : '${m.storage}${path.first.isIndex ? '' : '.'}${joinPath(path)}';
      final node = resolveStoragePath(root, storagePath);
      if (node == null) continue;
      final error = validateValue(node, v is String ? v : jsonEncode(v));
      if (error != null) {
        return ('cannot write data: $storagePath: $error', 'snapd validates the whole databag against the schema after the write.');
      }
    }
  }
  // Anything in the value no rule consumed.
  bool isUsed(List<String> at) => used.any((u) {
    final parts = u.isEmpty ? const <String>[] : u.split('\u0000');
    return parts.length <= at.length && List.generate(parts.length, (i) => parts[i] == at[i]).every((x) => x);
  });
  String? unused;
  void walk(List<String> at, Object? v) {
    if (unused != null) return;
    if (isUsed(at)) return;
    if (v is Map && v.isNotEmpty) {
      v.forEach((k, x) => walk([...at, '$k'], x));
    } else if (v is List && v.isNotEmpty) {
      for (var i = 0; i < v.length; i++) {
        walk([...at, '$i'], v[i]);
      }
    } else {
      unused = at.isEmpty ? text : at.join('.');
    }
  }

  walk(const [], value);
  if (unused != null) {
    return ('value contains unused data: $unused', 'No matching rule’s path reaches `$unused`, so snapd rejects the whole value.');
  }
  return null;
}
