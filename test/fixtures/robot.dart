// A schema with placeholders, shared by tests and screenshots.
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/schema_codec.dart';

/// Sensors and actuators, with placeholders, a nested map of values, an
/// alias, a list and a field filter.
final _robotDecoded = decodeStorage({
  'storage': {
    'aliases': {
      'actuator': {
        'type': 'map',
        'schema': {'mode': 'string', 'speed': 'int'},
      },
    },
    'schema': {
      'sensors': {
        'schema': {
          'accelerometers': {
            'type': 'map',
            'values': {
              'type': 'map',
              'schema': {'x': 'number', 'y': 'number'},
            },
          },
        },
      },
      'actuators': {'type': 'map', 'values': r'${actuator}'},
      'thresholds': {'type': 'array', 'values': 'int'},
      'free': 'any',
    },
  },
});

final robotStorage = _robotDecoded.storage;
final robotAliases = _robotDecoded.aliases;

const robotRules = [
  ViewRule(request: 'accelerometers.{sensor}', storage: 'sensors.accelerometers.{sensor}', access: RuleAccess.readWrite),
  ViewRule(request: 'actuators.{act}', storage: 'actuators.{act}[.mode={mode}]', access: RuleAccess.readWrite),
  ViewRule(request: 'thresholds[{n}]', storage: 'thresholds[{n}]', access: RuleAccess.readWrite),
  ViewRule(request: 'free.{a}.{b}', storage: 'free.{a}.{b}', access: RuleAccess.read),
];

ConfdbSchema robotSchema([List<ViewRule> rules = robotRules]) => ConfdbSchema(
  id: const SchemaId('acme', 'robot'),
  summary: 'Robot',
  storage: robotStorage,
  aliases: robotAliases,
  views: [ViewDef(name: 'control', rules: rules)],
  isDraft: true,
);
