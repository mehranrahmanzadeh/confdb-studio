// Simulates how snapd resolves a request through a view of a draft. Nothing is
// written and no hooks run.
import 'dart:convert';

import '../data/models.dart';
import 'access.dart';
import 'analysis.dart';
import 'values.dart';

enum SimState { passed, failed, skipped, info }

class SimStep {
  const SimStep({required this.title, required this.state, required this.statusLabel, required this.text, this.code, this.fixConnect});
  final String title;
  final SimState state;
  final String statusLabel;
  final String? code;

  /// Text with `backticked` identifiers.
  final String text;
  final ConfdbPlug? fixConnect;
}

class SimResult {
  const SimResult({required this.steps, required this.summary});
  final List<SimStep> steps;

  /// e.g. "Get `ssid` through `acme/network/wifi-admin` as `net-manager`".
  final String summary;

  bool get allowed => steps.every((s) => s.state != SimState.failed);
  int? get deniedAt {
    final i = steps.indexWhere((s) => s.state == SimState.failed);
    return i < 0 ? null : i + 1;
  }
}

class SimRequest {
  const SimRequest({required this.draft, required this.view, required this.path, required this.isSet, required this.snap, this.value});
  final ConfdbSchema draft;
  final String view;
  final String path;
  final bool isSet;
  final String? value;
  final SnapInfo snap;

  ViewRef get ref => draft.id.view(view);
}

/// `snapctl get --view :wifi-admin ssid`, as the snap would run it.
String snapctlCommand(SimRequest r) {
  final plug = r.snap.plugs.where((p) => p.view == r.ref).firstOrNull ?? r.snap.plugs.firstOrNull;
  final name = plug?.plug ?? r.view;
  if (r.isSet) return "snapctl set --view :$name ${r.path}=${shellQuote(r.value ?? '')}";
  return 'snapctl get --view :$name ${r.path}';
}

Future<SimResult> simulate(
  SimRequest r, {
  required List<SnapInfo> snaps,
  required Future<ViewSnapshot?> Function(ViewRef) readCurrent,
}) async {
  const titles = ['Request path matched a rule', 'Access check', 'Storage path', 'Current value', 'Hooks that would run'];
  final op = r.isSet ? 'Set' : 'Get';
  final summary = '$op `${r.path}` through `${r.ref.path}` as `${r.snap.name}`';
  final steps = <SimStep>[];

  SimResult stop() {
    for (var i = steps.length; i < titles.length; i++) {
      steps.add(
        SimStep(
          title: i == 3 && r.isSet ? 'Value check' : titles[i],
          state: SimState.skipped,
          statusLabel: 'Not reached',
          text: 'Not reached.',
        ),
      );
    }
    return SimResult(steps: steps, summary: summary);
  }

  final view = r.draft.view(r.view);
  final rules = view?.rules ?? const <ViewRule>[];
  final idx = rules.indexWhere((x) => x.request == r.path || r.path.startsWith('${x.request}.'));
  if (idx < 0) {
    steps.add(
      SimStep(title: titles[0], state: SimState.failed, statusLabel: 'Failed', text: 'No rule in `${r.view}` matches `${r.path}`.'),
    );
    return stop();
  }
  final rule = rules[idx];
  final storagePath = r.path == rule.request ? rule.storage : rule.storage + r.path.substring(rule.request.length);
  steps.add(
    SimStep(
      title: titles[0],
      state: SimState.passed,
      statusLabel: 'Passed',
      code: '${r.path} → $storagePath',
      text: 'Rule ${idx + 1} of ${rules.length} in `${r.view}`.',
    ),
  );

  // Access: the snap needs a connected plug for this view, and the rule must allow the operation.
  final plug = r.snap.plugs.where((p) => p.view == r.ref).firstOrNull;
  if (plug == null || !plug.state.isConnected) {
    final others = r.snap.plugs;
    final role = r.snap.isCustodian ? 'a custodian' : 'an observer';
    final plugsText = others.isEmpty
        ? 'no confdb plugs'
        : others.length == 1
        ? 'one plug, `${others.first.plug}`'
        : '${others.length} plugs, ${others.map((p) => '`${p.plug}`').join(', ')}';
    steps.add(
      SimStep(
        title: titles[1],
        state: SimState.failed,
        statusLabel: 'Failed',
        code: plug == null ? 'no connected plug for ${r.ref.path}' : 'plug ${plug.plug} is not connected',
        text: '`${r.snap.name}` is $role with $plugsText.',
        fixConnect: plug ?? others.firstOrNull,
      ),
    );
    return stop();
  }
  final allowed = r.isSet ? rule.access.canWrite : rule.access.canRead;
  if (!allowed) {
    steps.add(
      SimStep(
        title: titles[1],
        state: SimState.failed,
        statusLabel: 'Failed',
        code: '${rule.access.label}: ${op.toLowerCase()} not allowed',
        text: 'The rule for `${rule.request}` only allows ${rule.access.label}.',
      ),
    );
    return stop();
  }
  steps.add(
    SimStep(
      title: titles[1],
      state: SimState.passed,
      statusLabel: 'Passed',
      code: '${rule.access.label}: allowed',
      text: '`${r.snap.name}` is the ${plug.role.label.toLowerCase()} and its plug `${plug.plug}` is connected.',
    ),
  );

  final node = resolveStoragePath(r.draft.storage, storagePath);
  if (node == null) {
    steps.add(
      SimStep(
        title: titles[2],
        state: SimState.failed,
        statusLabel: 'Failed',
        code: storagePath,
        text: '`$storagePath` does not exist in the draft’s storage.',
      ),
    );
    return stop();
  }
  steps.add(
    SimStep(
      title: titles[2],
      state: SimState.passed,
      statusLabel: 'Passed',
      code: '$storagePath  ·  ${node.typeLabel}',
      text: [
        node.ephemeral ? 'Ephemeral; loaded by the custodian’s load-view hook when read.' : 'Stored value, not ephemeral.',
        if (node.secret) 'Marked secret: snapd leaves it out when non-admins read.',
      ].join(' '),
    ),
  );

  final custodian = custodianOf(r.ref, snaps);
  if (r.isSet) {
    final error = validateValue(node, r.value ?? '');
    steps.add(
      error == null
          ? SimStep(title: 'Value check', state: SimState.passed, statusLabel: 'Passed', code: r.value, text: 'Matches the storage schema.')
          : SimStep(title: 'Value check', state: SimState.failed, statusLabel: 'Failed', code: r.value, text: error),
    );
    if (error != null) return stop();
  } else if (node.ephemeral) {
    steps.add(
      SimStep(
        title: titles[3],
        state: SimState.info,
        statusLabel: 'Not loaded',
        text:
            'Ephemeral values are loaded by `load-view-${custodian?.plug ?? r.view}` on `${custodian?.snap ?? 'the custodian'}`; the playground doesn’t run hooks.',
      ),
    );
  } else {
    final snapshot = await readCurrent(r.ref);
    final entry = snapshot?.entries.where((e) => e.rule.storage == storagePath).firstOrNull;
    steps.add(
      SimStep(
        title: titles[3],
        state: SimState.passed,
        statusLabel: 'Passed',
        code: entry == null || !entry.hasValue ? 'unset' : (entry.masked ? '•••' : jsonEncode(entry.value)),
        text: snapshot == null ? 'The view isn’t acknowledged yet, so there is no stored value.' : 'Read from storage at simulation time.',
      ),
    );
  }

  final setHooks = custodian == null
      ? 'no hooks, because no custodian is connected'
      : '`change-view-${custodian.plug}` then `save-view-${custodian.plug}` on `${custodian.snap}`';
  if (r.isSet) {
    steps.add(
      SimStep(
        title: titles[4],
        state: SimState.info,
        statusLabel: custodian == null ? 'Would run: none' : 'Would run: 2 hooks',
        text: 'A Set would run $setHooks, then notify observers.',
      ),
    );
  } else if (node.ephemeral) {
    steps.add(
      SimStep(
        title: titles[4],
        state: SimState.info,
        statusLabel: 'Would run: 1 hook',
        text: 'A Get would run `load-view-${custodian?.plug ?? r.view}` on `${custodian?.snap ?? 'the custodian'}`.',
      ),
    );
  } else {
    steps.add(
      SimStep(
        title: titles[4],
        state: SimState.info,
        statusLabel: 'Would run: none',
        text: 'A Get of a stored value runs no hooks. Set (dry run) would run $setHooks.',
      ),
    );
  }
  return SimResult(steps: steps, summary: summary);
}
