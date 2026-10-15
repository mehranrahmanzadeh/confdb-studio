// The playground follows snapd's checks for `snapctl get/set --view`
// (overlord/hookstate/ctlcmd, overlord/confdbstate, confdb/confdb.go).
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/playground.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/robot.dart';

const _id = SchemaId('acme', 'sysprobe');

final _sysprobe = ConfdbSchema(
  id: _id,
  summary: '',
  storage: decodeStorage({
    'storage': {
      'schema': {
        'creds': {
          'schema': {
            'user': 'string',
            'secret-key': {'type': 'string', 'visibility': 'secret'},
          },
        },
        'status': {'type': 'string', 'ephemeral': true},
        'limits': {
          'schema': {'cpu': 'int', 'mem': 'int'},
        },
      },
    },
  }),
  views: const [
    ViewDef(
      name: 'admin',
      rules: [
        ViewRule(request: 'secret-key', storage: 'creds.secret-key', access: RuleAccess.readWrite),
        ViewRule(request: 'creds', storage: 'creds', access: RuleAccess.readWrite),
        ViewRule(request: 'status', storage: 'status', access: RuleAccess.read),
        ViewRule(request: 'cfg.cpu', storage: 'limits.cpu', access: RuleAccess.readWrite),
        ViewRule(request: 'cfg.mem', storage: 'limits.mem', access: RuleAccess.readWrite),
      ],
    ),
    ViewDef(
      name: 'watch',
      rules: [ViewRule(request: 'cpu', storage: 'limits.cpu', access: RuleAccess.read)],
    ),
  ],
  isDraft: true,
);

SnapInfo _snap(String name, PlugRole role, {ConnState state = ConnState.connected, String view = 'admin', List<String> hooks = const []}) =>
    SnapInfo(
      name: name,
      publisher: 'acme',
      revision: '1',
      plugs: [ConfdbPlug(snap: name, plug: view, view: ViewRef('acme', 'sysprobe', view), role: role, state: state)],
      hooks: [for (final h in hooks) DeclaredHook(h)],
    );

final _custodian = _snap('probe', PlugRole.custodian, hooks: ['change-view-admin', 'save-view-admin', 'load-view-admin']);
final _cli = _snap('probe-cli', PlugRole.observer);
final _watcher = _snap('watcher', PlugRole.observer, view: 'watch', hooks: ['observe-view-watch']);

SimResult _run(
  String path, {
  bool isSet = false,
  String? value,
  bool asRoot = false,
  SnapInfo? as,
  List<SnapInfo>? snaps,
  ConfdbSchema? draft,
  String view = 'admin',
}) {
  final all = snaps ?? [_custodian, _cli, _watcher];
  return simulate(
    SimRequest(draft: draft ?? _sysprobe, view: view, path: path, isSet: isSet, value: value, snap: as ?? _cli, asRoot: asRoot),
    snaps: all,
  );
}

SimStep _failed(SimResult r) => r.steps.firstWhere((s) => s.state == SimState.failed);

void main() {
  group('secrets', () {
    test('a user-run app can’t get a secret: unauthorized access', () {
      final r = _run('secret-key');
      expect(r.allowed, isFalse);
      expect(_failed(r).code, 'cannot get "secret-key" through acme/sysprobe/admin: unauthorized access');
    });
    test('a hook or service (root) gets admin access and can read it', () {
      expect(_run('secret-key', asRoot: true).allowed, isTrue);
    });
    test('reading the parent leaves the secret out', () {
      final r = _run('creds');
      expect(r.allowed, isTrue);
      expect(r.steps.last.state, SimState.warning);
      expect(r.steps.last.statusLabel, 'Secrets left out');
    });
    test('setting a secret has no visibility check', () {
      final r = _run('secret-key', isSet: true, value: 'hunter22');
      expect(r.allowed, isTrue);
      expect(r.steps[2].text, contains('can’t read it back'));
    });
  });

  group('custodian and hooks', () {
    test('every read needs a connected custodian, even of stored values', () {
      final r = _run('cfg.cpu', snaps: [_cli]);
      expect(_failed(r).code, 'cannot read confdb view acme/sysprobe/admin: no custodian snap connected');
      expect(r.deniedAt, 2);
    });
    test('and so does every write', () {
      final r = _run('cfg.cpu', isSet: true, value: '2', snaps: [_cli]);
      expect(_failed(r).code, 'cannot write confdb view acme/sysprobe/admin: no custodian snap connected');
    });
    test('a disconnected custodian doesn’t count', () {
      final r = _run(
        'cfg.cpu',
        snaps: [
          _snap('probe', PlugRole.custodian, state: ConnState.notConnected),
          _cli,
        ],
      );
      expect(_failed(r).code, contains('no custodian snap connected'));
    });
    test('an ephemeral read needs a custodian with a load-view hook', () {
      final r = _run(
        'status',
        snaps: [
          _snap('probe', PlugRole.custodian, hooks: ['change-view-admin']),
          _cli,
        ],
      );
      expect(
        _failed(r).code,
        'cannot schedule tasks to read view acme/sysprobe/admin: read might cover ephemeral data but no custodian has a load-view hook',
      );
      expect(_run('status').allowed, isTrue);
    });
    test('only declared hooks run; a set notifies other affected observers', () {
      final r = _run('cfg.cpu', isSet: true, value: '2');
      expect(r.steps.last.code, 'change-view-admin on probe\nsave-view-admin on probe\nobserve-view-watch on watcher');
      final read = _run('cfg.cpu');
      expect(read.steps[1].code, 'load-view-admin on probe');
    });
    test('the calling snap isn’t notified of its own change', () {
      final r = _run('cpu', view: 'watch', isSet: false, as: _watcher);
      expect(r.steps.first.state, SimState.passed);
      final set = _run('cfg.cpu', isSet: true, value: '2', as: _watcher, snaps: [_custodian, _watcher]);
      expect(set.deniedAt, 1, reason: 'watcher has no plug for the admin view');
    });
  });

  group('rule matching', () {
    test('a request longer than the rule doesn’t match', () {
      final r = _run('cfg.cpu.x');
      expect(_failed(r).code, 'cannot get "cfg.cpu.x" through acme/sysprobe/admin: no matching rule');
    });
    test('a prefix of rule requests matches them all and merges them', () {
      final r = _run('cfg');
      expect(r.allowed, isTrue);
      expect(r.steps[2].code, 'cfg.cpu → limits.cpu\ncfg.mem → limits.mem');
    });
    test('rules without the needed access are skipped: no matching rule', () {
      final r = _run('status', isSet: true, value: 'up');
      expect(_failed(r).code, 'cannot set "status" through acme/sysprobe/admin: no matching rule');
      expect(_failed(r).text, contains('`status` (read)'));
    });
    test('placeholders bind from a concrete path', () {
      const snap = SnapInfo(
        name: 'robot-ctl',
        publisher: 'acme',
        revision: '1',
        plugs: [
          ConfdbPlug(
            snap: 'robot-ctl',
            plug: 'control',
            view: ViewRef('acme', 'robot', 'control'),
            role: PlugRole.custodian,
            state: ConnState.connected,
          ),
        ],
      );
      final r = simulate(
        SimRequest(draft: robotSchema(), view: 'control', path: 'accelerometers', isSet: false, snap: snap),
        snaps: const [snap],
      );
      expect(r.allowed, isTrue);
      expect(r.steps[2].code, 'accelerometers.{sensor} → sensors.accelerometers.{sensor}');
    });
  });

  group('set values', () {
    test('a value for a prefix request is split over the rules', () {
      expect(_run('cfg', isSet: true, value: '{"cpu": 2, "mem": 512}').allowed, isTrue);
    });
    test('parts of the value no rule reaches are rejected', () {
      final r = _run('cfg', isSet: true, value: '{"cpu": 2, "gpu": 1}');
      expect(_failed(r).code, 'value contains unused data: gpu');
    });
    test('empty containers are rejected', () {
      expect(_failed(_run('cfg', isSet: true, value: '{}')).code, 'cannot set empty container: must contain at least one scalar');
    });
    test('values are checked against the storage schema', () {
      expect(_failed(_run('cfg.cpu', isSet: true, value: '"lots"')).code, startsWith('cannot write data: limits.cpu'));
    });
  });

  test('a snap without a plug for the view is told to add one, not shown its other plugs', () {
    final r = _run('cpu', view: 'watch', as: _cli);
    final step = _failed(r);
    expect(step.missingPlug, isTrue);
    expect(step.fixConnect, isNull);
    expect(step.text, isNot(contains('probe-cli:admin')));
    expect(step.text, contains('doesn’t have a plug for this view'));
  });

  test('a plug that isn’t connected yet warns, quoting snapd’s error', () {
    final r = _run('cfg.cpu', as: _snap('probe-cli', PlugRole.observer, state: ConnState.notConnected));
    expect(r.steps.first.state, SimState.warning);
    expect(r.steps.first.code, 'cannot access confdb through unconnected plug :admin');
    expect(r.allowed, isTrue);
  });

  test('the sample data: proxy-state has no custodian, so browser-proxy’s get fails there', () {
    final snaps = seedSnaps();
    final r = simulate(
      SimRequest(
        draft: networkDraft,
        view: 'proxy-state',
        path: 'http',
        isSet: false,
        snap: snaps.firstWhere((s) => s.name == 'browser-proxy'),
      ),
      snaps: snaps,
    );
    expect(r.steps.first.state, SimState.warning);
    expect(_failed(r).code, contains('no custodian snap connected'));
  });
}
