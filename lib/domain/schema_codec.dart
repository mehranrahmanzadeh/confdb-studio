// Encode and decode confdb-schema data: the storage schema JSON (assertion
// body), the `views` header, `snap sign` input, and assertion text.
import 'dart:convert';

import '../data/models.dart';
import 'paths.dart';

class SchemaFormatException implements Exception {
  const SchemaFormatException(this.message, {this.line});
  final String message;
  final int? line;

  @override
  String toString() => line == null ? message : 'Line $line: $message';
}

// ---------------------------------------------------------------- storage

/// Decodes `{"storage": {"schema": {...}}}` or `{"schema": {...}}`, returning
/// the tree and the top-level `aliases` map (named reusable types).
///
/// Understands the parts of the confdb storage format the app shows:
/// `aliases` (referenced as `"${name}"`, kept as [StorageNode.aliasRef] on
/// the referencing node), maps with a `schema` (optionally with `required`
/// key combinations) or with typed `keys`/`values`, arrays, alternatives (a
/// list of types), `ephemeral` and `"visibility": "secret"` (snapd 2.76+).
/// Unknown types become `any`, so real assertions always load.
///
/// Enforces snapd's rules for aliases: no `ephemeral` or secret visibility
/// inside an alias type, and aliases can't reference other aliases. Also
/// enforces that alternatives of one entry are either all secret or all not.
({StorageNode storage, Map<String, StorageNode> aliases}) decodeStorage(Object? json) {
  if (json is! Map) throw const SchemaFormatException('Storage must be a JSON object');
  final inner = json.containsKey('storage') ? json['storage'] : json;
  if (inner is! Map || inner['schema'] is! Map) {
    throw const SchemaFormatException('Expected "storage": { "schema": { … } }');
  }
  final rawAliases = inner['aliases'] is Map ? Map<String, Object?>.from(inner['aliases'] as Map) : const <String, Object?>{};
  final aliasNodes = <String, StorageNode>{};
  for (final e in rawAliases.entries) {
    if (_hasSecret(e.value)) throw SchemaFormatException('Alias "${e.key}" defines a secret; secrets can’t be defined inside alias types');
    if (_hasEphemeral(e.value)) throw SchemaFormatException('Alias "${e.key}" is ephemeral; aliases can’t be ephemeral');
    // Aliases can't reference other aliases: decode with no aliases known.
    aliasNodes[e.key] = _StorageDecoder(const {}, const {}).node(e.key, e.value, 'aliases.${e.key}');
  }
  final decoder = _StorageDecoder(rawAliases, aliasNodes);
  return (storage: StorageNode.root(decoder.children(inner['schema'] as Map, '')), aliases: aliasNodes);
}

bool _isSecret(Object? v) => v is Map && v['visibility'] == 'secret';

/// Whether a definition, or anything inside it, is marked secret.
bool _hasSecret(Object? v) => switch (v) {
  Map() => _isSecret(v) || v.values.any(_hasSecret),
  List() => v.any(_hasSecret),
  _ => false,
};

bool _isEphemeral(Object? v) => v is Map && v['ephemeral'] == true;

/// Whether a definition, or anything inside it, is marked ephemeral.
bool _hasEphemeral(Object? v) => switch (v) {
  Map() => _isEphemeral(v) || v.values.any(_hasEphemeral),
  List() => v.any(_hasEphemeral),
  _ => false,
};

/// A map's `"required"` constraint: either a flat list of keys (one required
/// combination) or a list of alternative combinations, e.g.
/// `["name", "revision"]` or `[["name", "revision"], ["id"]]`. Every key
/// named must have a "schema" entry.
List<List<String>> requiredCombos(Object? raw, String path, Set<String> schemaKeys) {
  if (raw == null) return const [];
  if (raw is! List) throw SchemaFormatException('"$path.required" must be a list');
  final combos = raw.isNotEmpty && raw.first is List
      ? [
          for (final c in raw)
            if (c is List) [for (final k in c) '$k'] else throw SchemaFormatException('"$path.required" must be a list of lists'),
        ]
      : [
          [for (final k in raw) '$k'],
        ];
  for (final combo in combos) {
    for (final k in combo) {
      if (!schemaKeys.contains(k)) {
        throw SchemaFormatException('"$path.required" names "$k", which has no "schema" entry');
      }
    }
  }
  return combos;
}

class _StorageDecoder {
  _StorageDecoder(this.rawAliases, this.aliasNodes);

  /// Raw JSON of each top-level alias, for resolving labels (`typeName`,
  /// `inline`) inside maps/arrays/alternatives that use one.
  final Map<String, Object?> rawAliases;

  /// Decoded alias definitions, for building [StorageNode.aliasRef] nodes.
  final Map<String, StorageNode> aliasNodes;

  static final _ref = RegExp(r'^\$\{(.+)\}$');

  /// Follows `"${alias}"` references (with a depth limit against cycles).
  Object? resolve(Object? v, [int depth = 0]) {
    if (v is String && depth < 16) {
      final m = _ref.firstMatch(v);
      if (m != null) {
        if (!rawAliases.containsKey(m[1])) throw SchemaFormatException('Unknown alias "${m[1]}"');
        return resolve(rawAliases[m[1]], depth + 1);
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
    final v = resolve(raw);
    if (v is String) return v;
    if (v is Map) return v['type'] as String? ?? (v.containsKey('schema') || v.containsKey('values') ? 'map' : 'any');
    return 'any';
  }

  /// [v] with every alias reference replaced by its definition, since the
  /// body is written back without `aliases`.
  Object? inline(Object? v, [int depth = 0]) {
    final r = resolve(v);
    if (depth > 32) return r;
    return switch (r) {
      Map() => {for (final e in r.entries) e.key: inline(e.value, depth + 1)},
      List() => [for (final x in r) inline(x, depth + 1)],
      _ => r,
    };
  }

  /// The full definition of a map's values or an array's elements, unless
  /// it's a plain type name.
  StorageNode? valuesNode(Object? values, String path) {
    if (values == null || values is String && !_ref.hasMatch(values)) return null;
    return node(StorageNode.placeholderKey, values, '$path.${StorageNode.placeholderKey}');
  }

  StorageNode node(String key, Object? raw, String path) {
    if (raw is String) {
      final m = _ref.firstMatch(raw);
      if (m != null) {
        final name = m[1]!;
        final def = aliasNodes[name];
        if (def == null) throw SchemaFormatException('Unknown alias "$name" at "$path"');
        return def.asAliasRef(key, name);
      }
      return StorageNode(key: key, kind: kind(raw));
    }
    final v = raw;
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
      final keysNode = schema is Map || v['keys'] == null ? null : node('keys', v['keys'], '$path.keys');
      if (keysNode != null && keysNode.aliasRef != null && keysNode.kind != StorageKind.string) {
        throw SchemaFormatException('"$path.keys" uses alias "${keysNode.aliasRef}", which isn’t string-based');
      }
      if (v['required'] != null && schema is! Map) {
        throw SchemaFormatException('"$path" has a "required" constraint but no "schema" constraint');
      }
      final schemaKeys = schema is Map ? schema.keys.map((k) => k as String).toSet() : const <String>{};
      final required = requiredCombos(v['required'], path, schemaKeys);
      return StorageNode(
        key: key,
        kind: k,
        children: schema is Map ? children(schema, path) : const [],
        ephemeral: v['ephemeral'] == true,
        valuesType: schema is Map ? null : typeName(values),
        valuesNode: schema is Map ? null : valuesNode(values, path),
        keys: keysNode,
        secret: secret,
        required: required,
      );
    }
    final rawChoices = v['choices'] as List?;
    if (rawChoices != null) {
      if (k == StorageKind.string && v['pattern'] != null) {
        throw SchemaFormatException('"$path" can’t have both "choices" and "pattern"');
      }
      if ((k == StorageKind.int || k == StorageKind.number) && (v['min'] != null || v['max'] != null)) {
        throw SchemaFormatException('"$path" can’t have both "choices" and "min"/"max"');
      }
    }
    if (v['unique'] != null && k != StorageKind.array) {
      throw SchemaFormatException('"$path" has a "unique" constraint but isn’t an array');
    }
    return StorageNode(
      key: key,
      kind: k,
      choices: [for (final c in (rawChoices ?? const [])) '$c'],
      pattern: v['pattern'] as String?,
      min: v['min'] as num?,
      max: v['max'] as num?,
      ephemeral: v['ephemeral'] == true,
      valuesType: typeName(values),
      valuesNode: valuesNode(values, path),
      secret: secret,
      unique: k == StorageKind.array && v['unique'] == true,
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
      raw: inline(raw),
    );
  }

  StorageKind kind(String s) => StorageKind.values.where((k) => k.name == s).firstOrNull ?? StorageKind.any;
}

Object? _encodeValues(StorageNode n) => n.valuesNode == null ? n.valuesType : _encodeNode(n.valuesNode!);

/// `"choices"` as numbers for `int`/`number` nodes, as strings otherwise
/// ([StorageNode.choices] is always kept as strings internally).
List<Object> _encodeChoices(StorageNode n) => switch (n.kind) {
  StorageKind.int => [for (final c in n.choices) int.parse(c)],
  StorageKind.number => [for (final c in n.choices) num.parse(c)],
  _ => n.choices,
};

Object _encodeNode(StorageNode n) {
  if (n.aliasRef != null) return '\${${n.aliasRef}}';
  if (n.raw != null) return n.raw!;
  if (n.isMap) {
    if (n.valuesType != null && n.children.isEmpty) {
      return {
        'type': 'map',
        if (n.keys != null) 'keys': _encodeNode(n.keys!),
        'values': _encodeValues(n),
        if (n.ephemeral) 'ephemeral': true,
        if (n.secret) 'visibility': 'secret',
      };
    }
    return {
      'schema': {for (final c in n.children) c.key: _encodeNode(c)},
      if (n.required.isNotEmpty) 'required': n.required.length == 1 ? n.required.first : n.required,
      if (n.ephemeral) 'ephemeral': true,
      if (n.secret) 'visibility': 'secret',
    };
  }
  final simple = !n.isEnum && n.pattern == null && n.min == null && n.max == null && !n.ephemeral && n.valuesType == null && !n.secret;
  if (simple) return n.kind.name;
  return {
    'type': n.kind.name,
    if (n.isEnum) 'choices': _encodeChoices(n),
    if (n.pattern != null) 'pattern': n.pattern,
    if (n.min != null) 'min': n.min,
    if (n.max != null) 'max': n.max,
    if (n.valuesType != null) 'values': _encodeValues(n),
    if (n.kind == StorageKind.array && n.unique) 'unique': true,
    if (n.ephemeral) 'ephemeral': true,
    if (n.secret) 'visibility': 'secret',
  };
}

Map<String, Object?> encodeStorage(StorageNode root, {Map<String, StorageNode> aliases = const {}}) => {
  'storage': {
    if (aliases.isNotEmpty) 'aliases': {for (final e in aliases.entries) e.key: _encodeNode(e.value)},
    'schema': {for (final c in root.children) c.key: _encodeNode(c)},
  },
};

/// Pretty JSON like the design: maps expand, short leaf objects stay inline.
String prettyStorageJson(StorageNode root, {Map<String, StorageNode> aliases = const {}}) {
  final b = StringBuffer();
  void write(Object? v, int indent) {
    final pad = '  ' * indent;
    if (v is Map) {
      final inline = jsonEncode(v).replaceAll('":', '": ').replaceAll(',"', ', "').replaceAll('","', '", "');
      final isLeaf = !v.containsKey('schema') && !v.containsKey('storage') && !v.containsKey('aliases');
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

  write(encodeStorage(root, aliases: aliases), 0);
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
        parameters: _decodeParameters((e.value as Map?)?['parameters'], e.key as String),
        rules: [for (final r in ((e.value as Map?)?['rules'] as List? ?? const [])) ..._decodeRule(r as Map)],
      ),
  ];
}

/// Decodes a top-level view rule. A `content` of plain `{storage: field}`
/// entries (the shape this editor itself writes, and snapd's common case)
/// collapses into a single [ViewRule] with that subset of fields; anything
/// more exotic (its own `request`/`access`, or further nesting) falls back to
/// [_flattenRule], so no information is lost even though the editor can't
/// show it as a subset picker.
List<ViewRule> _decodeRule(Map r) {
  final storage = r['storage'] as String?;
  if (storage == null) throw const SchemaFormatException('A view rule has no "storage"');
  final request = r['request'] as String? ?? storage;
  final access = r['access'] is String ? RuleAccess.parse(r['access'] as String) : RuleAccess.readWrite;
  final content = r['content'];
  if (content is List && content.isNotEmpty) {
    final fields = <String>[];
    for (final c in content) {
      final simple =
          c is Map &&
          c['storage'] is String &&
          !(c['storage'] as String).contains('.') &&
          !(c['storage'] as String).startsWith('[') &&
          (c['request'] == null || c['request'] == c['storage']) &&
          c['access'] == null &&
          c['content'] == null;
      if (!simple) return _flattenRule(r, null, null, null);
      fields.add(c['storage'] as String);
    }
    return [ViewRule(request: request, storage: storage, access: access, content: fields)];
  }
  return [ViewRule(request: request, storage: storage, access: access)];
}

/// Flattens nested `content` rules into leaf rules: a child's request and
/// storage are relative to its parent's, and it inherits the parent's access.
/// Used for `content` shapes [_decodeRule] can't represent as a field subset.
List<ViewRule> _flattenRule(Map r, String? parentRequest, String? parentStorage, RuleAccess? parentAccess) {
  final storagePart = r['storage'] as String?;
  if (storagePart == null) throw const SchemaFormatException('A view rule has no "storage"');
  final requestPart = r['request'] as String? ?? storagePart;
  // Like snapd: a nested path starting with `[` is appended without a dot.
  String join(String? parent, String part) => parent == null ? part : '$parent${part.startsWith('[') ? '' : '.'}$part';
  final request = join(parentRequest, requestPart);
  final storage = join(parentStorage, storagePart);
  final access = r['access'] is String ? RuleAccess.parse(r['access'] as String) : (parentAccess ?? RuleAccess.readWrite);
  final content = r['content'];
  if (content is List && content.isNotEmpty) {
    return [for (final c in content) ..._flattenRule(c as Map, request, storage, access)];
  }
  return [ViewRule(request: request, storage: storage, access: access)];
}

Map<String, ParameterDef> _decodeParameters(Object? json, String view) {
  if (json == null) return const {};
  if (json is! Map) throw SchemaFormatException('"parameters" of view "$view" must be an object');
  final params = <String, ParameterDef>{};
  for (final e in json.entries) {
    final value = e.value is Map ? e.value as Map : const {};
    final summary = value['summary'] as String?;
    final presence = value['presence'];
    if (presence == null || presence == '') {
      params['${e.key}'] = ParameterDef(summary: summary);
    } else if (presence is String && parameterPresences.contains(presence)) {
      params['${e.key}'] = ParameterDef(summary: summary, presence: presence);
    } else {
      throw SchemaFormatException('Parameter "${e.key}" of view "$view" needs a "presence" of ${parameterPresences.join(', ')}');
    }
  }
  return params;
}

/// The view's declared parameters plus any field filter uses without one
/// (declared optional), since snapd rejects undeclared filter parameters.
Map<String, ParameterDef> effectiveParameters(ViewDef v) => {
  for (final r in v.rules)
    for (final p in filterParams(r.storage)) p: const ParameterDef(),
  ...v.parameters,
};

Map<String, Object?> encodeViews(List<ViewDef> views) => {
  for (final v in views)
    v.name: {
      if (v.summary != null) 'summary': v.summary,
      if (effectiveParameters(v) case final params when params.isNotEmpty)
        'parameters': {
          for (final e in params.entries)
            e.key: {
              if (e.value.summary != null) 'summary': e.value.summary,
              if (e.value.presence != 'optional') 'presence': e.value.presence,
            },
        },
      'rules': [
        for (final r in v.rules)
          {
            'request': r.request,
            'storage': r.storage,
            'access': r.access.label,
            if (r.content.isNotEmpty)
              'content': [
                for (final f in r.content) {'storage': f},
              ],
          },
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
  'body': jsonEncode(encodeStorage(draft.storage, aliases: draft.aliases)),
};

// ------------------------------------------------------- assertion preview

/// Renders [draft] the way confdb's documentation shows a signed
/// confdb-schema assertion: aligned YAML headers (`type`, `authority-id`,
/// `account-id`, `name`, `summary`, `views`) followed by a blank line and the
/// JSON storage body — everything but the headers' values and the body are
/// unsigned/unknown until `snap sign`, so this is illustrative only.
String formatAssertionPreview(ConfdbSchema draft) {
  final headers = <String, Object?>{
    'type': 'confdb-schema',
    'authority-id': draft.id.account,
    'account-id': draft.id.account,
    'name': draft.id.name,
    if (draft.summary.isNotEmpty) 'summary': draft.summary,
  };
  final width = headers.keys.map((k) => k.length + 1).reduce((a, b) => a > b ? a : b) + 1;
  final buf = StringBuffer();
  for (final e in headers.entries) {
    buf.writeln('${'${e.key}:'.padRight(width)}${_yamlScalar(e.value)}');
  }
  final views = encodeViews(draft.views);
  if (views.isNotEmpty) {
    buf.writeln('views:');
    buf.write(_yamlMap(views, 1));
  }
  buf.writeln();
  buf.write(const JsonEncoder.withIndent('  ').convert(encodeStorage(draft.storage, aliases: draft.aliases)));
  return buf.toString();
}

String _yamlMap(Map<String, Object?> map, int indent) {
  final pad = '  ' * indent;
  final buf = StringBuffer();
  for (final e in map.entries) {
    if (e.value is Map && (e.value as Map).isNotEmpty) {
      buf.writeln('$pad${e.key}:');
      buf.write(_yamlMap((e.value as Map).cast<String, Object?>(), indent + 1));
    } else if (e.value is List && (e.value as List).isNotEmpty) {
      buf.writeln('$pad${e.key}:');
      buf.write(_yamlList((e.value as List).cast<Object?>(), indent + 1));
    } else if (e.value is Map || e.value is List) {
      buf.writeln('$pad${e.key}: ${e.value is Map ? '{}' : '[]'}');
    } else {
      buf.writeln('$pad${e.key}: ${_yamlScalar(e.value)}');
    }
  }
  return buf.toString();
}

String _yamlList(List<Object?> list, int indent) {
  final pad = '  ' * indent;
  final buf = StringBuffer();
  for (final item in list) {
    buf.writeln('$pad-');
    if (item is Map && item.isNotEmpty) {
      buf.write(_yamlMap(item.cast<String, Object?>(), indent + 1));
    } else if (item is List && item.isNotEmpty) {
      buf.write(_yamlList(item.cast<Object?>(), indent + 1));
    } else if (item is! Map && item is! List) {
      buf.writeln('$pad  ${_yamlScalar(item)}');
    }
  }
  return buf.toString();
}

/// A plain scalar, or a double-quoted one if it holds characters (`"`, `:`)
/// that would otherwise be ambiguous in YAML, matching confdb's docs.
String _yamlScalar(Object? v) {
  if (v is! String) return '$v';
  if (v.isEmpty || v.contains('"') || v.contains(': ') || v.endsWith(':')) {
    return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return v;
}

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
  final decoded = body == null ? null : decodeStorage(body);
  return ConfdbSchema(
    id: SchemaId(account, name),
    builtIn: builtIn,
    signedBy: builtIn ? null : headers['authority-id'] as String?,
    revision: builtIn ? null : int.tryParse('${headers['revision'] ?? '0'}'),
    summary: headers['summary'] as String? ?? '',
    views: decodeViews(headers['views'] ?? const {}),
    storage: decoded?.storage ?? const StorageNode.root([]),
    aliases: decoded?.aliases ?? const {},
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
