// Editing the storage tree of a draft, keeping view rules in step.
import '../data/models.dart';
import 'paths.dart' as paths;

final _keyPattern = RegExp(r'^[a-z0-9](-?[a-z0-9])*$');

/// Alias names, like snapd's `validAliasName`: unlike storage keys, they
/// must start with a letter.
final _aliasNamePattern = RegExp(r'^[a-z](-?[a-z0-9])*$');

/// Joins a parent path and a key: `wifi` + `band` → `wifi.band`, or
/// `devices` + `[{n}]` → `devices[{n}]` (no dot before a bracketed index).
String joinPath(String? parent, String key) => parent == null || parent.isEmpty ? key : joinTreePath(parent, key);

/// Parent of a path, or null at the top level.
String? parentOf(String path) {
  final segs = splitTreePath(path);
  return segs.length <= 1 ? null : joinSegments(segs.take(segs.length - 1));
}

/// Validation message for a storage key among its [siblings], or null.
String? validateStorageKey(String key, Iterable<String> siblings) {
  if (key.isEmpty) return 'Enter a key';
  if (!_keyPattern.hasMatch(key)) return 'Lowercase letters, digits and single dashes';
  if (siblings.contains(key)) return 'A key with this name exists here';
  return null;
}

/// Keys directly under [parent] (the root when null).
List<String> siblingKeys(StorageNode root, String? parent) => [
  for (final c in (parent == null ? root : root.lookup(parent))?.children ?? const <StorageNode>[]) c.key,
];

/// Maps a schema can hold children in: `null` for the top level, then each map path.
List<String?> mapPaths(StorageNode root) => [
  null,
  for (final (_, path, node) in root.walk())
    if (node.isMap && !node.hasPlaceholder) path,
];

/// Replaces the node at [path] with [node], keeping its position among siblings.
/// A `{placeholder}` segment is a map's placeholder (its values); a `[{n}]` segment is
/// an array's map-typed element.
StorageNode replaceAt(StorageNode root, String path, StorageNode node) {
  final segs = splitTreePath(path);
  StorageNode go(StorageNode parent, int i) {
    if (segs[i] == StorageNode.placeholderKey || segs[i] == StorageNode.indexKey) {
      return parent.withElement(i == segs.length - 1 ? node : go(parent.element!, i + 1));
    }
    return parent.copyWith(
      children: [
        for (final c in parent.children)
          if (c.key != segs[i]) c else if (i == segs.length - 1) node else go(c, i + 1),
      ],
    );
  }

  return go(root, 0);
}

/// Removes the node at [path]. Removing a placeholder leaves an empty map.
StorageNode removeAt(StorageNode root, String path) {
  final segs = splitTreePath(path);
  StorageNode go(StorageNode parent, int i) {
    if (segs[i] == StorageNode.placeholderKey || segs[i] == StorageNode.indexKey) {
      return i == segs.length - 1 ? parent.withElement(null) : parent.withElement(go(parent.element!, i + 1));
    }
    return parent.copyWith(
      children: [
        for (final c in parent.children)
          if (c.key != segs[i]) c else if (i < segs.length - 1) go(c, i + 1),
      ],
    );
  }

  return go(root, 0);
}

/// Points rules at [to] where they pointed at [from] (or below it). [from]
/// and [to] differ in their last key; placeholders in a rule's storage match
/// the tree's `{placeholder}`, and its own names and field filters are kept.
List<ViewDef> renameStorage(List<ViewDef> views, String from, String to) {
  final f = paths.tryParsePath(from);
  final newKey = to.split('.').last;
  String rename(String storage) {
    final s = paths.tryParsePath(storage);
    if (f == null || s == null || s.length < f.length) return storage;
    for (var i = 0; i < f.length; i++) {
      final (a, b) = (f[i], s[i]);
      if (a.toString() != b.toString() && !(a.isPlaceholder && b.isPlaceholder && a.isIndex == b.isIndex)) return storage;
    }
    final last = s[f.length - 1];
    return paths.joinPath([
      ...s.take(f.length - 1),
      paths.PathSegment(last.kind, newKey, last.filters),
      ...s.skip(f.length),
    ], filters: true);
  }

  return [
    for (final v in views) v.copyWith(rules: [for (final r in v.rules) r.copyWith(storage: rename(r.storage))]),
  ];
}

/// Renames [from] to [to] in a set of paths (and paths under it).
Set<String> renamePaths(Set<String> paths, String from, String to) => {
  for (final p in paths)
    if (p == from) to else if (p.startsWith('$from.') || p.startsWith('$from[')) to + p.substring(from.length) else p,
};

// ------------------------------------------------------------------ aliases

/// Validation message for an alias name among the schema's other [existing]
/// alias names, or null. Unlike storage keys, an alias name must start with
/// a letter (snapd's `validAliasName`).
String? validateAliasName(String name, Iterable<String> existing) {
  if (name.isEmpty) return 'Enter a name';
  if (!_aliasNamePattern.hasMatch(name)) return 'Lowercase letters, digits and single dashes, starting with a letter';
  if (existing.contains(name)) return 'An alias with this name exists';
  return null;
}

/// Validation message for a view's parameter name among its [existing]
/// parameter names, or null. Same shape as a placeholder/alias name.
String? validateParameterName(String name, Iterable<String> existing) {
  if (name.isEmpty) return 'Enter a name';
  if (!_aliasNamePattern.hasMatch(name)) return 'Lowercase letters, digits and single dashes, starting with a letter';
  if (existing.contains(name)) return 'A parameter with this name exists';
  return null;
}

/// How many places in [root] reference each alias, by name.
Map<String, int> aliasUsage(StorageNode root) {
  final usage = <String, int>{};
  void count(StorageNode n) {
    if (n.aliasRef != null) usage[n.aliasRef!] = (usage[n.aliasRef!] ?? 0) + 1;
    for (final c in n.children) {
      count(c);
    }
    if (n.valuesNode != null) count(n.valuesNode!);
    if (n.keys != null) count(n.keys!);
  }

  count(root);
  return usage;
}
