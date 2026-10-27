// Domain model for confdb as the app sees it. Every backend (fake, snapd REST,
// snap CLI) maps its data into these types.
import 'package:flutter/foundation.dart';

/// Splits a tree path into its segments, treating a bracketed index (e.g.
/// `[{n}]`) as its own segment even when it isn't preceded by a dot, matching
/// real confdb syntax (`devices[{n}].name`, not `devices.[{n}].name`).
List<String> splitTreePath(String path) {
  final segs = <String>[];
  final buf = StringBuffer();
  var i = 0;
  while (i < path.length) {
    final ch = path[i];
    if (ch == '.') {
      if (buf.isNotEmpty) {
        segs.add(buf.toString());
        buf.clear();
      }
      i++;
    } else if (ch == '[') {
      if (buf.isNotEmpty) {
        segs.add(buf.toString());
        buf.clear();
      }
      final end = path.indexOf(']', i);
      segs.add(path.substring(i, end + 1));
      i = end + 1;
    } else {
      buf.write(ch);
      i++;
    }
  }
  if (buf.isNotEmpty) segs.add(buf.toString());
  return segs;
}

/// Joins [key] onto [prefix], the inverse of [splitTreePath]: no dot before a
/// bracketed index.
String joinTreePath(String prefix, String key) => prefix.isEmpty || key.startsWith('[') ? '$prefix$key' : '$prefix.$key';

/// Joins tree-path segments back into a single path, the inverse of
/// [splitTreePath].
String joinSegments(Iterable<String> segs) {
  var out = '';
  for (final s in segs) {
    out = joinTreePath(out, s);
  }
  return out;
}

/// The full storage path of every leaf in a `content` tree: [prefix] itself
/// joined with each field's own key, recursing into any nested `children`.
Iterable<String> _contentLeafPaths(String prefix, List<ContentField> fields) sync* {
  for (final f in fields) {
    final path = joinTreePath(prefix, f.key);
    if (f.children.isEmpty) {
      yield path;
    } else {
      yield* _contentLeafPaths(path, f.children);
    }
  }
}

/// `<account>/<schema>`, e.g. `acme/network`.
@immutable
class SchemaId {
  const SchemaId(this.account, this.name);

  factory SchemaId.parse(String path) {
    final parts = path.split('/');
    if (parts.length != 2) throw FormatException('Expected <account>/<schema>', path);
    return SchemaId(parts[0], parts[1]);
  }

  final String account;
  final String name;

  String get path => '$account/$name';

  ViewRef view(String view) => ViewRef(account, name, view);

  @override
  bool operator ==(Object other) => other is SchemaId && other.account == account && other.name == name;

  @override
  int get hashCode => Object.hash(account, name);

  @override
  String toString() => path;
}

/// `<account>/<schema>/<view>`, e.g. `acme/network/wifi-admin`.
@immutable
class ViewRef {
  const ViewRef(this.account, this.schema, this.view);

  factory ViewRef.parse(String path) {
    final parts = path.split('/');
    if (parts.length != 3) throw FormatException('Expected <account>/<schema>/<view>', path);
    return ViewRef(parts[0], parts[1], parts[2]);
  }

  final String account;
  final String schema;
  final String view;

  SchemaId get schemaId => SchemaId(account, schema);
  String get path => '$account/$schema/$view';

  @override
  bool operator ==(Object other) => other is ViewRef && other.account == account && other.schema == schema && other.view == view;

  @override
  int get hashCode => Object.hash(account, schema, view);

  @override
  String toString() => path;
}

enum RuleAccess {
  read('read'),
  write('write'),
  readWrite('read-write');

  const RuleAccess(this.label);
  final String label;

  bool get canRead => this != write;
  bool get canWrite => this != read;

  /// Short form used in view chips: `r`, `w`, `rw`.
  String get short => switch (this) {
    read => 'r',
    write => 'w',
    readWrite => 'rw',
  };

  static RuleAccess parse(String s) => switch (s) {
    'read' => read,
    'write' => write,
    'read-write' => readWrite,
    _ => throw FormatException('Unknown access', s),
  };

  RuleAccess union(RuleAccess other) {
    if (this == other) return this;
    return readWrite;
  }
}

/// One entry of a view rule's `content`: a field exposed under the rule's
/// storage, at any depth. Empty [children] means the whole subtree under
/// [key] is exposed; a non-empty [children] exposes only that subset,
/// recursively. [key] is a single storage-path segment relative to its
/// parent (a plain field name, a `{placeholder}` map key, or a `[{n}]`/
/// `[index]` array element), never dotted.
@immutable
class ContentField {
  const ContentField({required this.key, this.children = const []});

  final String key;
  final List<ContentField> children;

  ContentField copyWith({String? key, List<ContentField>? children}) =>
      ContentField(key: key ?? this.key, children: children ?? this.children);

  @override
  bool operator ==(Object other) => other is ContentField && other.key == key && listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(key, Object.hashAll(children));
}

/// Maps a request path (what snaps and users see) to a storage path.
@immutable
class ViewRule {
  const ViewRule({required this.request, required this.storage, required this.access, this.content = const []});

  final String request;
  final String storage;
  final RuleAccess access;

  /// Fields exposed individually instead of the whole value at [storage]
  /// (confdb's `content` rules), at any depth: each leaf becomes its own
  /// `storage`/`request` path, with the rule's own [access].
  final List<ContentField> content;

  ViewRule copyWith({String? request, String? storage, RuleAccess? access, List<ContentField>? content}) => ViewRule(
    request: request ?? this.request,
    storage: storage ?? this.storage,
    access: access ?? this.access,
    content: content ?? this.content,
  );

  /// The storage paths actually exposed: [storage] itself, or one per leaf
  /// of [content] when it's used to expose only a subset.
  Iterable<String> get exposedStoragePaths => content.isEmpty ? [storage] : _contentLeafPaths(storage, content);

  @override
  bool operator ==(Object other) =>
      other is ViewRule &&
      other.request == request &&
      other.storage == storage &&
      other.access == access &&
      listEquals(other.content, content);

  @override
  int get hashCode => Object.hash(request, storage, access, Object.hashAll(content));
}

/// Allowed `presence` values for a view's declared parameter.
const parameterPresences = ['optional', 'required-on-read', 'required-on-write', 'required'];

/// A view's declared field-filter parameter (the `parameters` stanza): a
/// `{param}` used in a storage path's `[.field={param}]` must name one of
/// these. Parameters used without being declared are implicitly `optional`.
@immutable
class ParameterDef {
  const ParameterDef({this.summary, this.presence = 'optional'});

  /// Context on how the parameter may be used to filter data.
  final String? summary;

  /// Whether the user must constrain it, and for which access.
  final String presence;

  ParameterDef copyWith({String? summary, String? presence}) =>
      ParameterDef(summary: summary ?? this.summary, presence: presence ?? this.presence);

  @override
  bool operator ==(Object other) => other is ParameterDef && other.summary == summary && other.presence == presence;

  @override
  int get hashCode => Object.hash(summary, presence);
}

@immutable
class ViewDef {
  const ViewDef({required this.name, required this.rules, this.summary, this.parameters = const {}});

  final String name;
  final List<ViewRule> rules;
  final String? summary;

  /// The `parameters` stanza: field-filter parameter name → its declaration.
  final Map<String, ParameterDef> parameters;

  /// The broadest access any rule grants; shown next to the view name.
  RuleAccess get access => rules.isEmpty ? RuleAccess.read : rules.map((r) => r.access).reduce((a, b) => a.union(b));

  ViewRule? ruleFor(String request) {
    for (final r in rules) {
      if (r.request == request) return r;
    }
    return null;
  }

  ViewDef copyWith({String? name, List<ViewRule>? rules, String? summary, Map<String, ParameterDef>? parameters}) => ViewDef(
    name: name ?? this.name,
    rules: rules ?? this.rules,
    summary: summary ?? this.summary,
    parameters: parameters ?? this.parameters,
  );
}

enum StorageKind { map, string, int, number, bool, array, any }

/// A node in the storage schema tree. The root is an unnamed map.
@immutable
class StorageNode {
  const StorageNode({
    required this.key,
    required this.kind,
    this.children = const [],
    this.choices = const [],
    this.pattern,
    this.min,
    this.max,
    this.ephemeral = false,
    this.valuesType,
    this.secret = false,
    this.alternatives = const [],
    this.raw,
    this.valuesNode,
    this.keys,
    this.aliasRef,
    this.required = const [],
    this.unique = false,
  });

  /// The path segment for a map's values: any key (a placeholder in rules).
  static const placeholderKey = '{key}';

  /// The path segment for an array's elements: one per index.
  static const indexKey = '[{n}]';

  const StorageNode.root(List<StorageNode> children) : this(key: '', kind: StorageKind.map, children: children);

  final String key;
  final StorageKind kind;
  final List<StorageNode> children;

  /// Fixed set of allowed values for a `string`, `int` or `number` node
  /// (`"choices"`), exclusive with [pattern]/[min]/[max].
  final List<String> choices;
  final String? pattern;
  final num? min;
  final num? max;
  final bool ephemeral;

  /// Element type for arrays (`array<string>`).
  final String? valuesType;

  /// `"visibility": "secret"` (snapd 2.76+): snapd hides it, and anything
  /// inside it, from non-admins.
  final bool secret;

  /// Labels of an alternative (union) type, e.g. `string | int`.
  final List<String> alternatives;

  /// The original JSON, for definitions the app shows but doesn't model
  /// (alternatives); written back unchanged.
  final Object? raw;

  /// The full definition of map values or array elements when it's more than
  /// a type name (a nested map, an alias, constraints); [valuesType] labels it.
  final StorageNode? valuesNode;

  /// Name of the user-defined alias this node's type references (`"${name}"`
  /// in JSON), or null for an inline type. The other fields still describe
  /// the alias's underlying type, for display; snapd disallows any
  /// constraint (including `ephemeral`/`secret`) alongside an alias reference.
  final String? aliasRef;

  /// A map (with a fixed `"schema"`) is valid if at least one of these key
  /// combinations is fully present, e.g. `[["name", "revision"]]` or
  /// `[["name"], ["id"]]` for alternatives. Empty: no requirement.
  final List<List<String>> required;

  /// `"unique"`: an array may not hold two equal elements. Arrays only.
  final bool unique;

  /// What a `{placeholder}` key or `[index]` stands for: the map's values or
  /// the array's elements.
  StorageNode? get element =>
      valuesNode ??
      (valuesType == null
          ? null
          : StorageNode(key: placeholderKey, kind: StorageKind.values.where((k) => k.name == valuesType).firstOrNull ?? StorageKind.any));

  /// `"keys"`: what a map's keys must look like (a string type, e.g. with a
  /// pattern). Only for maps with a placeholder.
  final StorageNode? keys;

  /// A map whose keys are free (`"values"`) rather than fixed (`"schema"`).
  bool get hasPlaceholder => isMap && children.isEmpty && (valuesNode != null || valuesType != null);

  /// [key] for display: the internal `{key}` marker reads as `<placeholder>`.
  String get displayKey => key == placeholderKey ? '<placeholder>' : key;

  bool get isMap => kind == StorageKind.map;
  bool get isEnum => choices.isNotEmpty;

  String get typeLabel {
    if (aliasRef != null) return aliasRef!;
    if (alternatives.isNotEmpty) return alternatives.join(' | ');
    if (kind == StorageKind.array) return 'array<${element?.aliasRef ?? valuesType ?? 'any'}>';
    return kind.name;
  }

  /// Human-readable constraints, e.g. `min 0 · max 100` or `pattern: URL`.
  String? get constraintSummary {
    final parts = <String>[
      if (isEnum) choices.join(' | '),
      if (pattern != null) 'pattern: ${_describePattern(pattern!)}',
      if (min != null) 'min $min',
      if (max != null) 'max $max',
      if (kind == StorageKind.array && unique) 'unique',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _describePattern(String p) => p == r'^https?://' ? 'URL' : p;

  /// Whether an array's elements are themselves maps a user can add fields
  /// to in the tree (as opposed to a scalar type or an alias).
  bool get hasMapElement => kind == StorageKind.array && (element?.isMap ?? false);

  StorageNode? lookup(String path) {
    if (path.isEmpty) return this;
    StorageNode node = this;
    for (final seg in splitTreePath(path)) {
      if (seg == placeholderKey && node.hasPlaceholder) {
        node = node.element!;
        continue;
      }
      if (seg == indexKey && node.hasMapElement) {
        node = node.element!;
        continue;
      }
      final next = node.children.where((c) => c.key == seg);
      if (next.isEmpty) return null;
      node = next.first;
    }
    return node;
  }

  /// Children, then the placeholder for a map's values (keyed [placeholderKey]).
  Iterable<StorageNode> get _treeChildren sync* {
    yield* children;
    if (hasPlaceholder) yield element!;
  }

  /// Every non-map node with its dotted/bracketed path, depth first. An
  /// array's map-typed element (keyed [indexKey]) is also walked, in
  /// addition to the array itself.
  Iterable<(String, StorageNode)> leaves([String prefix = '']) sync* {
    for (final c in _treeChildren) {
      final p = joinTreePath(prefix, c.key);
      if (c.isMap) {
        yield* c.leaves(p);
      } else {
        yield (p, c);
      }
      if (c.hasMapElement) yield* c.element!.withKey(indexKey).leaves(joinTreePath(p, indexKey));
    }
  }

  /// Every node (maps included) with depth and dotted/bracketed path, depth
  /// first. An array's map-typed element (keyed [indexKey]) is also walked.
  Iterable<(int, String, StorageNode)> walk([String prefix = '', int depth = 0]) sync* {
    for (final c in _treeChildren) {
      final p = joinTreePath(prefix, c.key);
      yield (depth, p, c);
      if (c.isMap) yield* c.walk(p, depth + 1);
      if (c.hasMapElement) {
        final elem = c.element!.withKey(indexKey);
        final ep = joinTreePath(p, indexKey);
        yield (depth + 1, ep, elem);
        yield* elem.walk(ep, depth + 2);
      }
    }
  }

  /// Returns a copy with [leaf] inserted at [path], creating maps as needed.
  StorageNode insert(String path, StorageNode leaf) {
    final segs = splitTreePath(path);
    if (segs.first == placeholderKey || segs.first == indexKey) {
      final rest = joinSegments(segs.skip(1));
      return withElement(
        segs.length == 1 ? leaf : (element ?? const StorageNode(key: placeholderKey, kind: StorageKind.map)).insert(rest, leaf),
      );
    }
    if (segs.length == 1) {
      return copyWith(children: [...children.where((c) => c.key != segs.first), leaf]);
    }
    final head = segs.first;
    final rest = joinSegments(segs.skip(1));
    final existing = children.where((c) => c.key == head).firstOrNull ?? StorageNode(key: head, kind: StorageKind.map);
    final updated = existing.insert(rest, leaf);
    return copyWith(children: [for (final c in children) c.key == head ? updated : c, if (!children.contains(existing)) updated]);
  }

  StorageNode copyWith({List<StorageNode>? children, List<List<String>>? required, bool? unique}) => StorageNode(
    key: key,
    kind: kind,
    children: children ?? this.children,
    choices: choices,
    pattern: pattern,
    min: min,
    max: max,
    ephemeral: ephemeral,
    valuesType: valuesType,
    secret: secret,
    alternatives: alternatives,
    raw: raw,
    valuesNode: valuesNode,
    keys: keys,
    aliasRef: aliasRef,
    required: required ?? this.required,
    unique: unique ?? this.unique,
  );

  /// This map with [e] as its values (a placeholder), or with none.
  StorageNode withElement(StorageNode? e) => _with(
    key: key,
    valuesNode: e?.withKey(placeholderKey),
    valuesType: e == null ? null : (e.alternatives.isNotEmpty ? 'any' : e.kind.name),
    keys: e == null ? null : keys,
  );

  /// This map with [k] as its `"keys"` constraint.
  StorageNode withKeys(StorageNode? k) => _with(key: key, valuesNode: valuesNode, valuesType: valuesType, keys: k);

  StorageNode withKey(String k) => _with(key: k, valuesNode: valuesNode, valuesType: valuesType, keys: keys);

  /// This node's type as a reference to alias [name] at [key] (its
  /// constraints come from the alias; `ephemeral`/`secret` can't apply to a
  /// reference, since snapd writes it as the bare string `"${name}"`).
  StorageNode asAliasRef(String key, String name) => StorageNode(
    key: key,
    kind: kind,
    children: children,
    choices: choices,
    pattern: pattern,
    min: min,
    max: max,
    valuesType: valuesType,
    valuesNode: valuesNode,
    keys: keys,
    aliasRef: name,
    required: required,
    unique: unique,
  );

  StorageNode _with({required String key, required StorageNode? valuesNode, required String? valuesType, required StorageNode? keys}) =>
      StorageNode(
        key: key,
        kind: kind,
        children: children,
        choices: choices,
        pattern: pattern,
        min: min,
        max: max,
        ephemeral: ephemeral,
        valuesType: valuesType,
        secret: secret,
        alternatives: alternatives,
        raw: raw,
        required: required,
        unique: unique,
        valuesNode: valuesNode,
        keys: keys,
        aliasRef: aliasRef,
      );
}

/// A confdb-schema: acknowledged assertion or local draft.
@immutable
class ConfdbSchema {
  const ConfdbSchema({
    required this.id,
    required this.views,
    required this.storage,
    this.revision,
    this.summary = '',
    this.builtIn = false,
    this.isDraft = false,
    this.baseRevision,
    this.signedBy,
    this.addedInDraft = const {},
    this.aliases = const {},
  });

  final SchemaId id;

  /// Assertion revision; null for built-in schemas and unsigned drafts.
  final int? revision;
  final String summary;
  final bool builtIn;
  final List<ViewDef> views;
  final StorageNode storage;

  /// User-defined reusable types (`"aliases"` in the storage schema), keyed
  /// by name; referenced from [storage] via [StorageNode.aliasRef].
  final Map<String, StorageNode> aliases;

  /// Drafts are local; [baseRevision] is the signed revision they started from.
  final bool isDraft;
  final int? baseRevision;
  final String? signedBy;

  /// Storage paths added in this draft (shown with a "New" badge).
  final Set<String> addedInDraft;

  ViewDef? view(String name) => views.where((v) => v.name == name).firstOrNull;

  /// Views (with access) whose rules map to [storagePath].
  List<(ViewDef, ViewRule)> viewsUsing(String storagePath) => [
    for (final v in views)
      for (final r in v.rules)
        if (r.exposedStoragePaths.contains(storagePath)) (v, r),
  ];

  ConfdbSchema copyWith({
    int? revision,
    List<ViewDef>? views,
    StorageNode? storage,
    bool? isDraft,
    int? baseRevision,
    Set<String>? addedInDraft,
    String? summary,
    Map<String, StorageNode>? aliases,
  }) => ConfdbSchema(
    id: id,
    revision: revision ?? this.revision,
    summary: summary ?? this.summary,
    builtIn: builtIn,
    views: views ?? this.views,
    storage: storage ?? this.storage,
    isDraft: isDraft ?? this.isDraft,
    baseRevision: baseRevision ?? this.baseRevision,
    signedBy: signedBy,
    addedInDraft: addedInDraft ?? this.addedInDraft,
    aliases: aliases ?? this.aliases,
  );
}

/// Validation hints the backend knows beyond the storage schema, e.g. that a
/// custodian's change-view hook rejects short passwords.
@immutable
class ValueHint {
  const ValueHint({this.minLength, this.description});
  final int? minLength;
  final String? description;
}

/// One request path of a view, with its value as read through the view.
@immutable
class ViewEntry {
  const ViewEntry({required this.rule, required this.node, this.value, this.hasValue = false, this.loadError, this.hint});

  final ViewRule rule;
  final StorageNode? node;

  /// Decoded JSON value; meaningful only when [hasValue].
  final Object? value;
  final bool hasValue;

  /// Set when an ephemeral value couldn't be loaded.
  final String? loadError;
  final ValueHint? hint;

  String get key => rule.request;
  bool get writeOnly => rule.access == RuleAccess.write;

  /// Marked secret in storage: non-admins never get the value back.
  bool get secret => node?.secret ?? false;

  /// Hidden from us either way, so edited masked and never displayed.
  bool get masked => writeOnly || secret;
  bool get ephemeral => node?.ephemeral ?? false;
  String get typeLabel => node?.typeLabel ?? 'any';
}

/// A hook that failed while reading or writing.
@immutable
class HookFailure {
  const HookFailure({required this.snap, required this.hook, required this.message, this.exitStatus, this.requestPath});
  final String snap;
  final String hook;
  final String message;
  final int? exitStatus;
  final String? requestPath;
}

@immutable
class ViewSnapshot {
  const ViewSnapshot({required this.ref, required this.schema, required this.entries, this.loadFailure});
  final ViewRef ref;
  final ConfdbSchema schema;
  final List<ViewEntry> entries;
  final HookFailure? loadFailure;

  ViewDef get view => schema.view(ref.view)!;
  bool get isEmpty => entries.every((e) => !e.hasValue && !e.writeOnly && e.loadError == null);
}

enum ChangeStatus {
  doing('In progress'),
  done('Done'),
  error('Error'),
  undone('Undone'),
  hold('Hold'),
  waiting('Waiting');

  const ChangeStatus(this.label);
  final String label;

  bool get isReady => this != doing && this != waiting;
}

enum ChangeStepState { user, passed, failed, rolledBack, running, pending }

@immutable
class HookOutput {
  const HookOutput({this.stdout = '', this.stderr = ''});
  final String stdout;
  final String stderr;
}

/// One step in a change's timeline. [title] may contain `backticked` identifiers.
@immutable
class ChangeStep {
  const ChangeStep({required this.title, required this.state, required this.meta, this.description, this.output});
  final String title;
  final ChangeStepState state;
  final String meta;
  final String? description;
  final HookOutput? output;
}

@immutable
class ValueDiff {
  const ValueDiff({
    required this.key,
    required this.storagePath,
    required this.before,
    required this.after,
    this.secret = false,
    this.afterRaw,
  });
  final String key;
  final String storagePath;

  /// Display strings (already masked when [secret]).
  final String before;
  final String after;
  final bool secret;

  /// The attempted value, when the backend knows it (used for "Retry with fix").
  final Object? afterRaw;
}

enum InitiatorKind { user, snap }

@immutable
class ConfdbChange {
  const ConfdbChange({
    required this.id,
    required this.kind,
    required this.summary,
    required this.initiator,
    required this.initiatorKind,
    required this.spawnTime,
    required this.status,
    this.detail,
    this.readyTime,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.view,
    this.values = const [],
    this.steps = const [],
    this.custodian,
    this.observers = const [],
    this.error,
    this.rejectedBy,
  });

  final int id;

  /// snapd change kind, e.g. `set-confdb`, `connect-snap`, `ack-schema`.
  final String kind;

  /// Summary with `backticked` identifiers.
  final String summary;
  final String? detail;
  final String initiator;
  final InitiatorKind initiatorKind;
  final DateTime spawnTime;
  final DateTime? readyTime;
  final ChangeStatus status;
  final int progressDone;
  final int progressTotal;
  final ViewRef? view;
  final List<ValueDiff> values;
  final List<ChangeStep> steps;
  final String? custodian;
  final List<String> observers;
  final String? error;

  /// Custodian snap that rejected the change, if any.
  final String? rejectedBy;

  String get label => '#$id';

  /// A copy with the written values (and view) filled in.
  ConfdbChange withValues(List<ValueDiff> values, ViewRef view) => ConfdbChange(
    id: id,
    kind: kind,
    summary: summary,
    initiator: initiator,
    initiatorKind: initiatorKind,
    spawnTime: spawnTime,
    status: status,
    detail: detail ?? values.map((v) => '${v.key} = ${v.secret ? '•••' : v.after.replaceAll('"', '')}').join(', '),
    readyTime: readyTime,
    progressDone: progressDone,
    progressTotal: progressTotal,
    view: this.view ?? view,
    values: values,
    steps: steps,
    custodian: custodian,
    observers: observers,
    error: error,
    rejectedBy: rejectedBy,
  );
}

enum PlugRole {
  custodian('Custodian'),
  observer('Observer');

  const PlugRole(this.label);
  final String label;
}

enum ConnState {
  connected('Connected'),
  autoConnected('Auto-connected'),
  notConnected('Not connected');

  const ConnState(this.label);
  final String label;
  bool get isConnected => this != notConnected;
}

/// A confdb plug of a snap, pointing at one view.
@immutable
class ConfdbPlug {
  const ConfdbPlug({required this.snap, required this.plug, required this.view, required this.role, required this.state});
  final String snap;
  final String plug;
  final ViewRef view;
  final PlugRole role;
  final ConnState state;

  String get id => '$snap:$plug';

  ConfdbPlug copyWith({ConnState? state}) => ConfdbPlug(snap: snap, plug: plug, view: view, role: role, state: state ?? this.state);
}

@immutable
class DeclaredHook {
  const DeclaredHook(this.name, {this.implemented = true});
  final String name;
  final bool implemented;
}

/// A snap with at least one confdb plug.
@immutable
class SnapInfo {
  const SnapInfo({
    required this.name,
    required this.publisher,
    required this.revision,
    required this.plugs,
    this.publisherSigned = true,
    this.installNote,
    this.hooks = const [],
    this.hooksKnown = true,
  });
  final String name;
  final String publisher;
  final String revision;
  final bool publisherSigned;

  /// e.g. "installed from a local file".
  final String? installNote;
  final List<ConfdbPlug> plugs;
  final List<DeclaredHook> hooks;

  /// False when the snap's hooks couldn't be read, so [hooks] may be incomplete.
  final bool hooksKnown;

  bool get isCustodian => plugs.any((p) => p.role == PlugRole.custodian);

  SnapInfo copyWith({List<ConfdbPlug>? plugs}) => SnapInfo(
    name: name,
    publisher: publisher,
    revision: revision,
    plugs: plugs ?? this.plugs,
    publisherSigned: publisherSigned,
    installNote: installNote,
    hooks: hooks,
    hooksKnown: hooksKnown,
  );
}

/// A Snap Store account, from its `account` assertion: a long random
/// `account-id` plus the username people know it by.
@immutable
class AccountInfo {
  const AccountInfo({required this.id, this.username, this.displayName});
  final String id;
  final String? username;
  final String? displayName;

  /// What to show instead of [id].
  String get alias => username ?? displayName ?? id;

  @override
  bool operator ==(Object other) =>
      other is AccountInfo && other.id == id && other.username == username && other.displayName == displayName;
  @override
  int get hashCode => Object.hash(id, username, displayName);
}

@immutable
class SigningKey {
  const SigningKey({required this.name, required this.sha3384});
  final String name;
  final String sha3384;

  /// `7Hq2Kf9xLwR3 … mT8vZp41`
  String get shortFingerprint => sha3384.length <= 24 ? sha3384 : '${sha3384.substring(0, 12)} … ${sha3384.substring(sha3384.length - 8)}';
}

@immutable
class SystemStatus {
  const SystemStatus({required this.snapdVersion, required this.confdbEnabled});
  final String snapdVersion;
  final bool confdbEnabled;
}

enum SignPhase { signing, pushing, acknowledging }

/// Which Snap Store the app signs in to.
enum StoreEnv {
  production('Production', 'dashboard.snapcraft.io'),
  staging('Staging', 'dashboard.staging.snapcraft.io');

  const StoreEnv(this.label, this.host);
  final String label;
  final String host;

  static StoreEnv parse(String? s) => s == 'staging' ? staging : production;
}

/// The app's own Snap Store login, used to list and register
/// schemas in the Store. Separate from snapcraft's, which signing keys need.
@immutable
class StoreSession {
  const StoreSession({required this.env, this.username, this.email, this.accountId}) : detail = null;
  const StoreSession.signedOut({this.detail}) : env = null, username = null, email = null, accountId = null;

  /// Null when signed out.
  final StoreEnv? env;
  final String? username;
  final String? email;
  final String? accountId;

  /// Why the session isn't usable, e.g. the Snap Store backend isn't available.
  final String? detail;

  bool get signedIn => env != null;
}

/// Thrown by repositories when snapd can't be reached or refuses a request.
class ConfdbException implements Exception {
  const ConfdbException(this.message, {this.command, this.kind = ConfdbErrorKind.other});
  final String message;

  /// A CLI command that helps diagnose the problem.
  final String? command;
  final ConfdbErrorKind kind;

  @override
  String toString() => message;
}

enum ConfdbErrorKind {
  unreachable,
  permissionDenied,
  notFound,
  unsupported,

  /// The Snap Store needs a sign-in (or a new one).
  signedOut,

  /// Ubuntu One wants the one-time code from the account's second factor.
  twoFactorRequired,

  /// The Snap Store couldn't be reached.
  offline,
  other,
}
