// Editing the storage tree of a draft, keeping view rules in step.
import '../data/models.dart';

final _keyPattern = RegExp(r'^[a-z0-9](-?[a-z0-9])*$');

/// Joins a parent path and a key: `wifi` + `band` → `wifi.band`.
String joinPath(String? parent, String key) => parent == null || parent.isEmpty ? key : '$parent.$key';

/// Parent of a dotted path, or null at the top level.
String? parentOf(String path) => path.contains('.') ? path.substring(0, path.lastIndexOf('.')) : null;

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
    if (node.isMap && node.valuesType == null) path,
];

/// Replaces the node at [path] with [node], keeping its position among siblings.
StorageNode replaceAt(StorageNode root, String path, StorageNode node) {
  final segs = path.split('.');
  StorageNode go(StorageNode parent, int i) => parent.copyWith(
    children: [
      for (final c in parent.children)
        if (c.key != segs[i]) c else if (i == segs.length - 1) node else go(c, i + 1),
    ],
  );
  return go(root, 0);
}

/// Removes the node at [path].
StorageNode removeAt(StorageNode root, String path) {
  final segs = path.split('.');
  StorageNode go(StorageNode parent, int i) => parent.copyWith(
    children: [
      for (final c in parent.children)
        if (c.key != segs[i]) c else if (i < segs.length - 1) go(c, i + 1),
    ],
  );
  return go(root, 0);
}

/// Points rules at [to] where they pointed at [from] (or below it).
List<ViewDef> renameStorage(List<ViewDef> views, String from, String to) => [
  for (final v in views)
    v.copyWith(
      rules: [
        for (final r in v.rules)
          if (r.storage == from)
            r.copyWith(storage: to)
          else if (r.storage.startsWith('$from.'))
            r.copyWith(storage: to + r.storage.substring(from.length))
          else
            r,
      ],
    ),
];

/// Renames [from] to [to] in a set of paths (and paths under it).
Set<String> renamePaths(Set<String> paths, String from, String to) => {
  for (final p in paths)
    if (p == from) to else if (p.startsWith('$from.')) to + p.substring(from.length) else p,
};
