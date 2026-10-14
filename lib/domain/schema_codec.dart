// Encode and decode confdb-schema data: the storage schema JSON (assertion
// body), the `views` header, `snap sign` input, and assertion text.
import 'dart:convert';

import '../data/models.dart';

class SchemaFormatException implements Exception {
  const SchemaFormatException(this.message, {this.line});
  final String message;
  final int? line;

  @override
  String toString() => line == null ? message : 'Line $line: $message';
}

// ---------------------------------------------------------------- storage

/// Decodes `{"storage": {"schema": {...}}}` or `{"schema": {...}}`.
///
/// Understands the parts of the confdb storage format the app shows:
/// `aliases` (referenced as `"${name}"`, inlined on decode), maps with a
/// `schema` or with typed `keys`/`values`, arrays, alternatives (a list of
/// types), `ephemeral` and `"visibility": "secret"` (snapd 2.76+). Other
/// keywords (`required`, …) are ignored, and unknown types become `any`, so
/// real assertions always load.
///
/// Enforces snapd's rules for secrets: none inside alias types, and the
/// alternatives of one entry are either all secret or all not.
StorageNode decodeStorage(Object? json) {
  if (json is! Map) throw const SchemaFormatException('Storage must be a JSON object');
  final inner = json.containsKey('storage') ? json['storage'] : json;
  if (inner is! Map || inner['schema'] is! Map) {
    throw const SchemaFormatException('Expected "storage": { "schema": { … } }');
  }
  final aliases = inner['aliases'] is Map ? Map<String, Object?>.from(inner['aliases'] as Map) : const <String, Object?>{};
  for (final e in aliases.entries) {
    if (_hasSecret(e.value)) throw SchemaFormatException('Alias "${e.key}" defines a secret; secrets can’t be defined inside alias types');
  }
  return StorageNode.root(_StorageDecoder(aliases).children(inner['schema'] as Map, ''));
}

bool _isSecret(Object? v) => v is Map && v['visibility'] == 'secret';

/// Whether a definition, or anything inside it, is marked secret.
bool _hasSecret(Object? v) => switch (v) {
  Map() => _isSecret(v) || v.values.any(_hasSecret),
  List() => v.any(_hasSecret),
  _ => false,
};

class _StorageDecoder {
  _StorageDecoder(this.aliases);
  final Map<String, Object?> aliases;

  static final _ref = RegExp(r'^\$\{(.+)\}$');

  /// Follows `"${alias}"` references (with a depth limit against cycles).
  Object? resolve(Object? v, [int depth = 0]) {
    if (v is String && depth < 16) {
      final m = _ref.firstMatch(v);
      if (m != null) {
        if (!aliases.containsKey(m[1])) throw SchemaFormatException('Unknown alias "${m[1]}"');
        return resolve(aliases[m[1]], depth + 1);
      }
    }
    return v;
  }

  List<StorageNode> children(Map schema, String prefix) => [
    for (final e in schema.entries) node(e.key as String, e.value, prefix.isEmpty ? e.key as String : '$prefix.${e.key}'),
  ];

  /// Short label for the element type of a map or array: `string`, `map`, `presence`…
  String? typeName(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      final m = _ref.firstMatch(raw);
      return m != null ? m[1] : raw;
    }
    final v = resolve(raw);
    if (v is Map) return v['type'] as String? ?? (v.containsKey('schema') || v.containsKey('values') ? 'map' : 'any');
    return 'any';
  }

  StorageNode node(String key, Object? raw, String path) {
    final v = resolve(raw);
    if (v is String) return StorageNode(key: key, kind: kind(v));
    if (v is List) return alternativesNode(key, raw, v, path);
    if (v is! Map) throw SchemaFormatException('"$path" must be a type name or an object');
    final secret = _isSecret(v);
    final schema = v['schema'];
    final values = v['values'];
    final type = v['type'] as String? ?? (schema is Map || values != null ? 'map' : null);
    if (type == null) throw SchemaFormatException('"$path" has no "type"');
    final k = kind(type);
    if (k == StorageKind.map) {
      if (schema is! Map && values == null) {
        throw SchemaFormatException('Map "$path" needs a "schema" object or a "values" type');
      }
      return StorageNode(
        key: key,
        kind: k,
        children: schema is Map ? children(schema, path) : const [],
        ephemeral: v['ephemeral'] == true,
        valuesType: schema is Map ? null : typeName(values),
        secret: secret,
      );
    }
    return StorageNode(
      key: key,
      kind: k,
      choices: [for (final c in (v['choices'] as List? ?? const [])) '$c'],
      pattern: v['pattern'] as String?,
      min: v['min'] as num?,
      max: v['max'] as num?,
      ephemeral: v['ephemeral'] == true,
      valuesType: typeName(values),
      secret: secret,
    );
  }

  /// An alternative type: a list of type names or definitions. Kept as raw
  /// JSON so it is written back unchanged.
  StorageNode alternativesNode(String key, Object? raw, List alts, String path) {
    if (alts.isEmpty) throw SchemaFormatException('"$path" lists no alternatives');
    final secrets = [for (final a in alts) _isSecret(resolve(a))];
    if (secrets.toSet().length > 1) {
      throw SchemaFormatException('The alternatives of "$path" must all be secret, or none of them');
    }
    return StorageNode(
      key: key,
      kind: StorageKind.any,
      alternatives: [for (final a in alts) typeName(a) ?? 'any'],
      secret: secrets.first,
      raw: raw,
    );
  }

  StorageKind kind(String s) => StorageKind.values.where((k) => k.name == s).firstOrNull ?? StorageKind.any;
}

Object _encodeNode(StorageNode n) {
  if (n.raw != null) return n.raw!;
  if (n.isMap) {
    if (n.valuesType != null && n.children.isEmpty) {
      return {'type': 'map', 'values': n.valuesType, if (n.ephemeral) 'ephemeral': true, if (n.secret) 'visibility': 'secret'};
    }
    return {
      'schema': {for (final c in n.children) c.key: _encodeNode(c)},
      if (n.ephemeral) 'ephemeral': true,
      if (n.secret) 'visibility': 'secret',
    };
  }
  final simple = !n.isEnum && n.pattern == null && n.min == null && n.max == null && !n.ephemeral && n.valuesType == null && !n.secret;
  if (simple) return n.kind.name;
  return {
    'type': n.kind.name,
    if (n.isEnum) 'choices': n.choices,
    if (n.pattern != null) 'pattern': n.pattern,
    if (n.min != null) 'min': n.min,
    if (n.max != null) 'max': n.max,
    if (n.valuesType != null) 'values': n.valuesType,
    if (n.ephemeral) 'ephemeral': true,
    if (n.secret) 'visibility': 'secret',
  };
}

Map<String, Object?> encodeStorage(StorageNode root) => {
  'storage': {
    'schema': {for (final c in root.children) c.key: _encodeNode(c)},
  },
};

/// Pretty JSON like the design: maps expand, short leaf objects stay inline.
String prettyStorageJson(StorageNode root) {
  final b = StringBuffer();
  void write(Object? v, int indent) {
    final pad = '  ' * indent;
    if (v is Map) {
      final inline = jsonEncode(v).replaceAll('":', '": ').replaceAll(',"', ', "').replaceAll('","', '", "');
      final isLeaf = !v.containsKey('schema') && !v.containsKey('storage');
      if (isLeaf && inline.length <= 50) {
        b.write('{ ${inline.substring(1, inline.length - 1)} }');
        return;
      }
      b.writeln('{');
      final entries = v.entries.toList();
      for (var i = 0; i < entries.length; i++) {
        b.write('$pad  "${entries[i].key}": ');
        write(entries[i].value, indent + 1);
        b.writeln(i < entries.length - 1 ? ',' : '');
      }
      b.write('$pad}');
    } else if (v is List) {
      b.write('[${v.map(jsonEncode).join(', ')}]');
    } else {
      b.write(jsonEncode(v));
    }
  }

  write(encodeStorage(root), 0);
  return b.toString();
}

// ------------------------------------------------------------------ views

List<ViewDef> decodeViews(Object? json) {
  if (json is! Map) throw const SchemaFormatException('"views" must be an object');
  return [
    for (final e in json.entries)
      ViewDef(
        name: e.key as String,
        summary: (e.value as Map?)?['summary'] as String?,
        rules: [for (final r in ((e.value as Map?)?['rules'] as List? ?? const [])) ..._flattenRule(r as Map, null, null, null)],
      ),
  ];
}

/// Flattens nested `content` rules into leaf rules: a child's request and
/// storage are relative to its parent's, and it inherits the parent's access.
List<ViewRule> _flattenRule(Map r, String? parentRequest, String? parentStorage, RuleAccess? parentAccess) {
  final storagePart = r['storage'] as String?;
  if (storagePart == null) throw const SchemaFormatException('A view rule has no "storage"');
  final requestPart = r['request'] as String? ?? storagePart;
  final request = parentRequest == null ? requestPart : '$parentRequest.$requestPart';
  final storage = parentStorage == null ? storagePart : '$parentStorage.$storagePart';
  final access = r['access'] is String ? RuleAccess.parse(r['access'] as String) : (parentAccess ?? RuleAccess.readWrite);
  final content = r['content'];
  if (content is List && content.isNotEmpty) {
    return [for (final c in content) ..._flattenRule(c as Map, request, storage, access)];
  }
  return [ViewRule(request: request, storage: storage, access: access)];
}

Map<String, Object?> encodeViews(List<ViewDef> views) => {
  for (final v in views)
    v.name: {
      if (v.summary != null) 'summary': v.summary,
      'rules': [
        for (final r in v.rules) {'request': r.request, 'storage': r.storage, 'access': r.access.label},
      ],
    },
};

// ------------------------------------------------------------ sign input

/// JSON accepted by `snap sign` for a confdb-schema assertion.
Map<String, Object?> signInput(ConfdbSchema draft, {required int revision, required DateTime timestamp}) => {
  'type': 'confdb-schema',
  'authority-id': draft.id.account,
  'account-id': draft.id.account,
  'name': draft.id.name,
  'revision': '$revision',
  if (draft.summary.isNotEmpty) 'summary': draft.summary,
  'views': encodeViews(draft.views),
  'timestamp': timestamp.toUtc().toIso8601String(),
  'body': jsonEncode(encodeStorage(draft.storage)),
};

// ----------------------------------------------------------- import files

/// Parses either `snap sign` input JSON or a signed assertion.
ConfdbSchema parseSchemaFile(String content) {
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('{')) {
    final Object? json;
    try {
      json = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw SchemaFormatException('Not valid JSON: ${e.message}');
    }
    if (json is! Map) throw const SchemaFormatException('Expected a JSON object');
    return schemaFromHeaders(
      json,
      json['body'] is String
          ? jsonDecode(json['body'] as String)
          : json['storage'] == null
          ? null
          : json,
    );
  }
  return parseAssertion(content);
}

/// Parses assertion text: headers, blank line, body, blank line, signature.
ConfdbSchema parseAssertion(String text) {
  final lines = const LineSplitter().convert(text);
  final blank = lines.indexWhere((l) => l.trim().isEmpty);
  final headerLines = blank < 0 ? lines : lines.sublist(0, blank);
  final headers = _parseHeaderBlock(headerLines);
  if (headers['type'] != 'confdb-schema') {
    throw SchemaFormatException('Expected type: confdb-schema, found ${headers['type'] ?? 'nothing'}');
  }
  Object? body;
  final bodyLength = int.tryParse('${headers['body-length'] ?? ''}');
  if (blank >= 0 && bodyLength != null && bodyLength > 0) {
    final rest = lines.sublist(blank + 1).join('\n');
    body = jsonDecode(rest.substring(0, bodyLength.clamp(0, rest.length)));
  }
  return schemaFromHeaders(headers, body);
}

/// Builds a schema from assertion headers (JSON or parsed text) and body.
ConfdbSchema schemaFromHeaders(Map headers, Object? body) {
  final account = headers['account-id'] as String?;
  final name = headers['name'] as String?;
  if (account == null || name == null) throw const SchemaFormatException('Missing account-id or name');
  // Assertions from the `system` account are built into snapd.
  final builtIn = account == 'system';
  return ConfdbSchema(
    id: SchemaId(account, name),
    builtIn: builtIn,
    signedBy: builtIn ? null : headers['authority-id'] as String?,
    revision: builtIn ? null : int.tryParse('${headers['revision'] ?? '0'}'),
    summary: headers['summary'] as String? ?? '',
    views: decodeViews(headers['views'] ?? const {}),
    storage: body == null ? const StorageNode.root([]) : decodeStorage(body),
  );
}

/// Minimal parser for the YAML subset used in assertion headers.
Map<String, Object?> _parseHeaderBlock(List<String> lines) {
  var i = 0;
  int indentOf(String l) => l.length - l.trimLeft().length;

  Object? parseBlock(int indent) {
    if (i < lines.length && lines[i].trimLeft().startsWith('-') && indentOf(lines[i]) == indent) {
      final list = <Object?>[];
      while (i < lines.length && indentOf(lines[i]) == indent && lines[i].trimLeft().startsWith('-')) {
        final item = lines[i].trimLeft().substring(1).trim();
        i++;
        if (item.isNotEmpty) {
          list.add(item);
        } else {
          list.add(parseBlock(i < lines.length ? indentOf(lines[i]) : indent + 2));
        }
      }
      return list;
    }
    final map = <String, Object?>{};
    while (i < lines.length && indentOf(lines[i]) == indent) {
      final line = lines[i].trim();
      final colon = line.indexOf(':');
      if (colon < 0) throw SchemaFormatException('Expected "key: value"', line: i + 1);
      final key = line.substring(0, colon);
      final value = line.substring(colon + 1).trim();
      i++;
      if (value.isNotEmpty) {
        map[key] = value;
      } else if (i < lines.length && indentOf(lines[i]) > indent) {
        map[key] = parseBlock(indentOf(lines[i]));
      } else {
        map[key] = '';
      }
    }
    return map;
  }

  return parseBlock(0) as Map<String, Object?>;
}
