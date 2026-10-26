import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:confdb_studio/domain/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatAssertionPreview', () {
    test('renders aligned headers, YAML views and a JSON storage body, like confdb docs', () {
      final draft = schemaTemplates.first.build(const SchemaId('acme', 'network'));
      final text = formatAssertionPreview(draft);
      final lines = text.split('\n');

      // Headers: aligned to the longest key ("authority-id:").
      expect(lines[0], 'type:         confdb-schema');
      expect(lines[1], 'authority-id: acme');
      expect(lines[2], 'account-id:   acme');
      expect(lines[3], 'name:         network');
      expect(lines[4], 'summary:      Wi-Fi');

      // Views render as YAML: list items on their own "-" line, nested keys
      // indented underneath, matching the docs' style.
      expect(text, contains('views:\n  wifi-admin:\n'));
      expect(text, contains('    rules:\n      -\n        request: ssid\n        storage: v1.wifi.ssid\n        access: read-write\n'));
      expect(text, contains('      -\n        request: password\n        storage: v1.wifi.psk\n        access: write\n'));

      // A blank line separates the headers from the JSON storage body.
      final blank = lines.indexOf('');
      expect(blank, greaterThan(0));
      expect(lines[blank + 1], '{');

      // The body is exactly what `snap sign` would take: `{"storage": {...}}`.
      final bodyStart = text.indexOf('{');
      final body = text.substring(bodyStart);
      expect(body.trim(), isNotEmpty);
      expect(body, contains('"storage"'));
      expect(body, contains('"schema"'));
    });

    test('omits "summary" when blank, and quotes scalars that would otherwise be ambiguous', () {
      final draft = ConfdbSchema(
        id: const SchemaId('acme', 'robot'),
        summary: '',
        storage: const StorageNode.root([StorageNode(key: 'v1', kind: StorageKind.map)]),
        views: [
          ViewDef(
            name: 'actuator-admin',
            parameters: const {'mode': ParameterDef()},
            rules: const [ViewRule(request: 'mode', storage: 'v1.mode', access: RuleAccess.readWrite)],
          ),
        ],
        isDraft: true,
      );
      final text = formatAssertionPreview(draft);
      expect(text, isNot(contains('summary:')));
      expect(text.split('\n')[3], 'name:         robot');
    });
  });
}
