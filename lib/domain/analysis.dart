// Schema analysis that doesn't need snapd: lint, quick-fix suggestions and the
// revision diff shown before signing.
import '../data/models.dart';
import 'paths.dart';

/// Resolves a storage path to its definition. A `{placeholder}` or concrete
/// key under a map with typed values gives the values' definition; `[0]` and
/// `[{n}]` give an array's elements; anything under `any` is `any`. Field
/// filters don't change what a path points to.
StorageNode? resolveStoragePath(StorageNode root, String path) {
  final segs = tryParsePath(path);
  return segs == null ? null : _resolve(root, segs, 0);
}

StorageNode? _resolve(StorageNode node, List<PathSegment> segs, int i) {
  if (i == segs.length) return node;
  final s = segs[i];
  if (node.kind == StorageKind.any && node.alternatives.isEmpty) return StorageNode(key: s.toString(), kind: StorageKind.any);
  if (s.isIndex) {
    final element = node.kind == StorageKind.array ? node.element : null;
    return element == null ? null : _resolve(element, segs, i + 1);
  }
  if (!node.isMap) return null;
  if (s.kind == SegmentKind.key) {
    final child = node.children.where((c) => c.key == s.name).firstOrNull;
    if (child != null) return _resolve(child, segs, i + 1);
  }
  if (node.children.isEmpty) {
    final element = node.element;
    return element == null ? null : _resolve(element, segs, i + 1);
  }
  // A placeholder over a map with fixed keys stands for any of them.
  if (s.kind == SegmentKind.keyPlaceholder) {
    for (final c in node.children) {
      final r = _resolve(c, segs, i + 1);
      if (r != null) return r;
    }
  }
  return null;
}

/// True when [rulePath] covers [storagePath]: equal or a parent of it,
/// segment by segment, where a placeholder on either side matches any key or
/// index. Field filters are ignored.
bool ruleCovers(String rulePath, String storagePath) {
  if (rulePath == storagePath || storagePath.startsWith('$rulePath.')) return true;
  final r = tryParsePath(rulePath);
  final s = tryParsePath(storagePath);
  if (r == null || s == null || r.length > s.length) return false;
  for (var i = 0; i < r.length; i++) {
    final (a, b) = (r[i], s[i]);
    if (a.toString() == b.toString()) continue;
    if (a.isIndex != b.isIndex) return false;
    if (!a.isPlaceholder && !b.isPlaceholder) return false;
  }
  return true;
}

/// True when [rule] actually exposes [storagePath]: like [ruleCovers] in
/// either direction, but checked against each of the rule's
/// [ViewRule.exposedStoragePaths] rather than its raw `storage`, so a
/// `content` subset doesn't make the whole map look exposed.
bool ruleExposes(ViewRule rule, String storagePath) =>
    rule.exposedStoragePaths.any((sp) => ruleCovers(sp, storagePath) || ruleCovers(storagePath, sp));

enum LintSeverity { error, warning }

class LintIssue {
  const LintIssue({
    required this.severity,
    required this.message,
    this.view,
    this.request,
    this.storagePath,
    this.suggestedLeaf,
    this.detail,
  });

  final LintSeverity severity;

  /// Message with `backticked` identifiers.
  final String message;
  final String? view;
  final String? request;
  final String? storagePath;

  /// For a missing storage path: the leaf the quick fix would add.
  final StorageNode? suggestedLeaf;

  /// Shorter wording for under the rule's own row, without the view prefix.
  final String? detail;

  bool get isError => severity == LintSeverity.error;
}

List<LintIssue> lintSchema(ConfdbSchema schema) {
  if (schema.builtIn) return const [];
  final issues = <LintIssue>[];
  for (final view in schema.views) {
    if (view.rules.isEmpty) {
      issues.add(LintIssue(severity: LintSeverity.warning, message: '`${view.name}` has no rules, so it exposes nothing', view: view.name));
    }
    // Access per request path seen so far, to flag only overlapping access
    // (e.g. two `read` rules, or a `read-write` next to anything else) and
    // allow non-overlapping pairs like `read` + `write` for the same path.
    final seen = <String, List<RuleAccess>>{};
    for (final rule in view.rules) {
      if (rule.request.trim().isEmpty || rule.storage.trim().isEmpty) {
        issues.add(
          LintIssue(
            severity: LintSeverity.error,
            message: '`${view.name}`: a rule is missing its request or storage path',
            view: view.name,
            request: rule.request,
          ),
        );
        continue;
      }
      final withSameRequest = seen.putIfAbsent(rule.request, () => []);
      final overlaps = withSameRequest.any((a) => (a.canRead && rule.access.canRead) || (a.canWrite && rule.access.canWrite));
      withSameRequest.add(rule.access);
      if (overlaps) {
        issues.add(
          LintIssue(
            severity: LintSeverity.error,
            message: '`${view.name}`: request path `${rule.request}` is used by more than one rule with overlapping access',
            view: view.name,
            request: rule.request,
          ),
        );
      }
      final pathProblems = checkRulePaths(rule.request, rule.storage);
      for (final p in pathProblems) {
        issues.add(
          LintIssue(
            severity: p.isError ? LintSeverity.error : LintSeverity.warning,
            message: '`${view.name}` › ${p.message}',
            view: view.name,
            request: rule.request,
            storagePath: rule.storage,
            detail: p.message,
          ),
        );
      }
      if (pathProblems.any((p) => p.isError)) continue;
      final filtered = _filterOnNonMap(schema.storage, rule.storage);
      if (filtered != null) {
        issues.add(
          LintIssue(
            severity: LintSeverity.error,
            message: '`${view.name}` › `${rule.request}`: field filters only work on maps, but `$filtered` isn’t one',
            view: view.name,
            request: rule.request,
            storagePath: rule.storage,
            detail: 'field filters only work on maps, but `$filtered` isn’t one',
          ),
        );
      }
      if (resolveStoragePath(schema.storage, rule.storage) == null) {
        issues.add(
          LintIssue(
            severity: LintSeverity.error,
            message: '`${view.name}` › `${rule.request}`: storage path `${rule.storage}` does not exist',
            view: view.name,
            request: rule.request,
            storagePath: rule.storage,
            detail: '`${rule.storage}` does not exist in storage',
            // Adding a leaf only makes sense for a plain dotted path.
            suggestedLeaf: tryParsePath(rule.storage)?.every((x) => x.kind == SegmentKind.key && x.filters.isEmpty) ?? false
                ? suggestLeaf(rule.storage)
                : null,
          ),
        );
      }
    }
  }
  for (final (path, _) in schema.storage.leaves()) {
    // A rule exposes a leaf when it covers it or reaches inside it (`list[{n}]`).
    final exposed = schema.views.any((v) => v.rules.any((r) => ruleExposes(r, path)));
    if (!exposed) {
      issues.add(
        LintIssue(severity: LintSeverity.warning, message: '`$path` is defined in storage but no view rule exposes it', storagePath: path),
      );
    }
  }
  return issues;
}

/// The first filtered part of [storage] that resolves to something other
/// than a map, as a path; null when every filter is on a map (or unresolved).
String? _filterOnNonMap(StorageNode root, String storage) {
  final segs = tryParsePath(storage) ?? const <PathSegment>[];
  for (var i = 0; i < segs.length; i++) {
    if (segs[i].filters.isEmpty) continue;
    final at = joinPath(segs.take(i + 1));
    final node = resolveStoragePath(root, at);
    if (node != null && !node.isMap && node.kind != StorageKind.any) return at;
  }
  return null;
}

const _liveNames = {'status', 'state', 'signal', 'strength', 'rssi', 'quality', 'uptime', 'connected', 'online'};
const _intNames = {'signal', 'strength', 'rssi', 'quality', 'level', 'percent', 'count', 'port', 'interval', 'retries', 'timeout'};
const _percentNames = {'signal', 'strength', 'quality', 'level', 'percent'};
const _boolNames = {'enabled', 'disabled', 'active', 'connected', 'online', 'on'};

/// A sensible leaf for a missing storage path, guessed from its name. The
/// author can change it in the JSON pane afterwards.
StorageNode suggestLeaf(String storagePath) {
  final name = storagePath.split('.').last;
  final kind = _boolNames.contains(name)
      ? StorageKind.bool
      : _intNames.contains(name)
      ? StorageKind.int
      : StorageKind.string;
  final pct = _percentNames.contains(name);
  return StorageNode(key: name, kind: kind, ephemeral: _liveNames.contains(name), min: pct ? 0 : null, max: pct ? 100 : null);
}

/// "int, ephemeral"
String describeLeaf(StorageNode n) => [n.typeLabel, if (n.ephemeral) 'ephemeral', if (n.secret) 'secret'].join(', ');

// ------------------------------------------------------------------ diff

class SchemaDiffLine {
  const SchemaDiffLine({required this.added, required this.where, required this.what});
  final bool added;

  /// View name, `storage` or `summary`.
  final String where;
  final String what;
}

/// What a draft changes compared to the revision it is based on.
List<SchemaDiffLine> diffSchemas(ConfdbSchema? base, ConfdbSchema draft) {
  final lines = <SchemaDiffLine>[];
  String rule(ViewRule r) => '${r.request} → ${r.storage}  ·  ${r.access.label}';

  if (base != null && base.summary != draft.summary) {
    if (base.summary.isNotEmpty) lines.add(SchemaDiffLine(added: false, where: 'summary', what: base.summary));
    if (draft.summary.isNotEmpty) lines.add(SchemaDiffLine(added: true, where: 'summary', what: draft.summary));
  }

  final viewNames = <String>{...?base?.views.map((v) => v.name), ...draft.views.map((v) => v.name)};
  for (final name in viewNames) {
    final old = base?.view(name);
    final now = draft.view(name);
    // A removed view is one line; its rules go with it.
    if (old != null && now == null) {
      lines.add(
        SchemaDiffLine(added: false, where: name, what: 'view and its ${old.rules.length == 1 ? '1 rule' : '${old.rules.length} rules'}'),
      );
      continue;
    }
    if (base != null && old == null) lines.add(SchemaDiffLine(added: true, where: name, what: 'new view'));
    final before = old?.rules ?? const <ViewRule>[];
    final after = now?.rules ?? const <ViewRule>[];
    for (final r in before) {
      if (!after.contains(r)) lines.add(SchemaDiffLine(added: false, where: name, what: rule(r)));
    }
    for (final r in after) {
      if (!before.contains(r)) lines.add(SchemaDiffLine(added: true, where: name, what: rule(r)));
    }
  }

  final oldLeaves = {for (final (p, n) in base?.storage.leaves() ?? const <(String, StorageNode)>[]) p: describeLeaf(n)};
  final newLeaves = {for (final (p, n) in draft.storage.leaves()) p: describeLeaf(n)};
  for (final e in oldLeaves.entries) {
    if (newLeaves[e.key] != e.value) {
      lines.add(SchemaDiffLine(added: false, where: 'storage', what: '${e.key}  ·  ${e.value}'));
    }
  }
  for (final e in newLeaves.entries) {
    if (oldLeaves[e.key] != e.value) {
      lines.add(SchemaDiffLine(added: true, where: 'storage', what: '${e.key}  ·  ${e.value}'));
    }
  }
  return lines;
}
