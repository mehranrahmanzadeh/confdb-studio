import 'dart:convert';

import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/analysis.dart';
import 'package:confdb_studio/domain/paths.dart';
import 'package:confdb_studio/domain/playground.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/robot.dart';

void main() {
  group('parsePath', () {
    test('reads keys, placeholders, indexes and filters', () {
      final segs = parsePath('actuators.{act}[.mode={mode}].list[{n}][2]');
      expect(segs.map((s) => s.kind), [
        SegmentKind.key,
        SegmentKind.keyPlaceholder,
        SegmentKind.key,
        SegmentKind.indexPlaceholder,
        SegmentKind.listIndex,
      ]);
      expect(segs[1].filters.single.toString(), '[.mode={mode}]');
      expect(joinPath(segs), 'actuators.{act}.list[{n}][2]');
      expect(joinPath(segs, filters: true), 'actuators.{act}[.mode={mode}].list[{n}][2]');
    });

    for (final bad in ['', 'a..b', 'a.', 'A', 'a.{B}', 'a[x]', 'a[.mode=fast]', 'a[.m={p}]b', 'a[.m={p}][0]', 'a[0]b', 'a[1', 'a.[0]']) {
      test('rejects "$bad"', () => expect(() => parsePath(bad), throwsA(isA<PathFormatException>())));
    }
  });

  group('checkRulePaths', () {
    List<String> errors(String request, String storage) => [
      for (final p in checkRulePaths(request, storage))
        if (p.isError) p.message,
    ];

    test('accepts matching placeholders and storage-only filters', () {
      for (final r in robotRules) {
        expect(errors(r.request, r.storage), isEmpty, reason: r.request);
      }
    });
    test('needs every request placeholder in storage', () {
      expect(errors('a.{x}', 'b.{y}').single, contains('`x`'));
    });
    test('needs the same number of placeholders', () => expect(errors('a', 'b.{y}'), isNotEmpty));
    test('rejects a placeholder used twice in the request', () => expect(errors('a.{x}.{x}', 'b.{x}.{x}'), isNotEmpty));
    test('rejects literal indexes in requests', () => expect(errors('a[0]', 'b[0]').single, contains('literal indexes')));
    test('rejects one name as both key and index placeholder', () => expect(errors('a.{x}[{x}]', 'b.{x}[{x}]'), isNotEmpty));
    test('allows literal indexes in storage', () => expect(errors('first', 'thresholds[0]'), isEmpty));
  });

  group('resolveStoragePath', () {
    test('follows placeholders into nested map values', () {
      expect(resolveStoragePath(robotStorage, 'sensors.accelerometers.{sensor}')?.isMap, isTrue);
      expect(resolveStoragePath(robotStorage, 'sensors.accelerometers.{sensor}.x')?.kind, StorageKind.number);
      expect(resolveStoragePath(robotStorage, 'sensors.accelerometers.front.y')?.kind, StorageKind.number);
      expect(resolveStoragePath(robotStorage, 'sensors.accelerometers.{sensor}.z'), isNull);
    });
    test('follows aliases, filters, list indexes and any', () {
      expect(resolveStoragePath(robotStorage, 'actuators.{act}[.mode={mode}]')?.isMap, isTrue);
      expect(resolveStoragePath(robotStorage, 'actuators.arm.speed')?.kind, StorageKind.int);
      expect(resolveStoragePath(robotStorage, 'thresholds[{n}]')?.kind, StorageKind.int);
      expect(resolveStoragePath(robotStorage, 'thresholds[3]')?.kind, StorageKind.int);
      expect(resolveStoragePath(robotStorage, 'free.{a}.{b}')?.kind, StorageKind.any);
    });
    test('a placeholder over fixed keys stands for any of them', () {
      expect(resolveStoragePath(robotStorage, 'sensors.{kind}')?.isMap, isTrue);
    });
  });

  test('the rules lint clean, and storage they cover is exposed', () {
    expect(lintSchema(robotSchema()).where((i) => i.isError), isEmpty);
    expect(ruleCovers('actuators.{act}[.mode={mode}]', 'actuators.arm.speed'), isTrue);
    expect(ruleCovers('thresholds[{n}]', 'thresholds[2]'), isTrue);
    expect(ruleCovers('thresholds[{n}]', 'thresholds.x'), isFalse);
  });

  test('lint names path problems on the rule, without a quick fix', () {
    final issues = lintSchema(
      robotSchema(const [
        ViewRule(request: 'a.{x}', storage: 'sensors.{y}', access: RuleAccess.read),
        ViewRule(request: 'speed', storage: 'thresholds[0][.mode={m}]', access: RuleAccess.read),
        ViewRule(request: 'gone.{g}', storage: 'sensors.gone.{g}', access: RuleAccess.read),
      ]),
    ).where((i) => i.isError).toList();
    expect(issues.map((i) => i.detail), [contains('missing from storage'), contains('only work on maps'), contains('does not exist')]);
    expect(issues.every((i) => i.suggestedLeaf == null), isTrue);
  });

  test('storage with aliases round-trips the reference, not an inlined copy', () {
    final body = encodeStorage(robotStorage, aliases: robotAliases);
    final again = decodeStorage(jsonDecode(jsonEncode(body)));
    expect(jsonEncode(encodeStorage(again.storage, aliases: again.aliases)), jsonEncode(body));
    final storage = body['storage']! as Map;
    expect(storage['aliases'], {
      'actuator': {
        'schema': {'mode': 'string', 'speed': 'int'},
      },
    });
    final schema = storage['schema'] as Map;
    expect((schema['actuators'] as Map)['values'], r'${actuator}');
    expect(((schema['sensors'] as Map)['schema'] as Map)['accelerometers'], {
      'type': 'map',
      'values': {
        'schema': {'x': 'number', 'y': 'number'},
      },
    });
    // The referencing node still behaves like the alias's own type (a map
    // with `mode`/`speed`), for lint, the tree view, etc.
    final actuator = again.storage.lookup('actuators.{placeholder}')!;
    expect(actuator.aliasRef, 'actuator');
    expect(actuator.lookup('mode')!.kind, StorageKind.string);
  });

  test('view parameters round-trip, and filter parameters get declared', () {
    final views = decodeViews({
      'control': {
        'parameters': {
          'zone': {'presence': 'required-on-read'},
        },
        'rules': [
          {'request': 'actuators.{act}', 'storage': 'actuators.{act}[.mode={mode}]'},
          {
            'request': 'list',
            'storage': 'thresholds',
            'content': [
              {'request': '[{n}]', 'storage': '[{n}]'},
            ],
          },
        ],
      },
    });
    expect(views.single.parameters, {'zone': const ParameterDef(presence: 'required-on-read')});
    expect(views.single.rules.last.request, 'list[{n}]', reason: 'nested `[` paths join without a dot');
    expect((encodeViews(views)['control']! as Map)['parameters'], {
      'mode': <String, Object?>{},
      'zone': {'presence': 'required-on-read'},
    });
  });

  test('the playground matches concrete paths against placeholder rules', () {
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
    SimResult run(String path) => simulate(
      SimRequest(draft: robotSchema(), view: 'control', path: path, isSet: true, value: '{"x": 1, "y": 2}', snap: snap),
      snaps: const [snap],
    );
    final ok = run('accelerometers.front');
    expect(ok.steps[1].code, 'accelerometers.front → sensors.accelerometers.front');
    expect(ok.steps[1].text, contains('`{sensor}` = `front`'));
    expect(ok.steps[2].state, SimState.passed);
    final filtered = run('actuators.arm');
    expect(filtered.steps[1].code, 'actuators.arm → actuators.arm');
    expect(filtered.steps[1].text, contains('aren’t simulated'));
    expect(run('thresholds[2]').steps[1].code, 'thresholds[2] → thresholds[2]');
  });

  test('the sample backend writes concrete keys and reads the collection back', () async {
    final repo = FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero));
    final key = (await repo.signingKeys()).first;
    await repo.signAndAcknowledge(robotSchema(), key);
    const ref = ViewRef('acme', 'robot', 'control');
    await repo.applyValues(ref, {
      'accelerometers.front': {'x': 1, 'y': 2},
      'accelerometers.rear': {'x': 3, 'y': 4},
    });
    final entry = (await repo.readView(ref)).entries.first;
    expect(entry.hasValue, isTrue);
    expect(entry.value, {
      'front': {'x': 1, 'y': 2},
      'rear': {'x': 3, 'y': 4},
    });
  });
}
