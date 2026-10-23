// Starting points offered in onboarding (Onboarding-Choose.dc.html).
import '../data/models.dart';

class SchemaTemplate {
  const SchemaTemplate({required this.id, required this.label, required this.paths, required this.build});
  final String id;
  final String label;

  /// Storage paths it creates, shown under the label.
  final String paths;
  final ConfdbSchema Function(SchemaId id) build;
}

const _r = RuleAccess.read;
const _w = RuleAccess.write;
const _rw = RuleAccess.readWrite;

ConfdbSchema _draft(SchemaId id, String summary, List<StorageNode> storage, List<ViewDef> views) =>
    ConfdbSchema(id: id, summary: summary, storage: StorageNode.root(storage), views: views, isDraft: true);

final schemaTemplates = <SchemaTemplate>[
  SchemaTemplate(
    id: 'wifi',
    label: 'Wi-Fi',
    paths: 'v1.wifi.ssid · v1.wifi.psk · v1.wifi.band · v1.wifi.status',
    build: (id) => _draft(
      id,
      'Wi-Fi',
      const [
        StorageNode(
          key: 'v1',
          kind: StorageKind.map,
          children: [
            StorageNode(
              key: 'wifi',
              kind: StorageKind.map,
              children: [
                StorageNode(key: 'ssid', kind: StorageKind.string),
                StorageNode(key: 'psk', kind: StorageKind.string, secret: true),
                StorageNode(key: 'band', kind: StorageKind.string, choices: ['2.4GHz', '5GHz', 'auto']),
                StorageNode(key: 'status', kind: StorageKind.string, ephemeral: true),
              ],
            ),
          ],
        ),
      ],
      const [
        ViewDef(
          name: 'wifi-admin',
          rules: [
            ViewRule(request: 'ssid', storage: 'v1.wifi.ssid', access: _rw),
            ViewRule(request: 'password', storage: 'v1.wifi.psk', access: _w),
            ViewRule(request: 'band', storage: 'v1.wifi.band', access: _rw),
            ViewRule(request: 'status', storage: 'v1.wifi.status', access: _r),
          ],
        ),
        ViewDef(
          name: 'wifi-state',
          summary: 'State of the Wi-Fi connection',
          rules: [
            ViewRule(request: 'ssid', storage: 'v1.wifi.ssid', access: _r),
            ViewRule(request: 'band', storage: 'v1.wifi.band', access: _r),
            ViewRule(request: 'status', storage: 'v1.wifi.status', access: _r),
          ],
        ),
      ],
    ),
  ),
  SchemaTemplate(
    id: 'kv',
    label: 'Minimal key/value',
    paths: 'v1.values.<name> (string map)',
    build: (id) => _draft(
      id,
      'Key/value store',
      const [
        StorageNode(
          key: 'v1',
          kind: StorageKind.map,
          children: [StorageNode(key: 'values', kind: StorageKind.map, valuesType: 'string')],
        ),
      ],
      const [
        ViewDef(
          name: 'values-admin',
          rules: [ViewRule(request: '{name}', storage: 'v1.values.{name}', access: _rw)],
        ),
      ],
    ),
  ),
];
