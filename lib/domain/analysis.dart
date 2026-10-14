// Schema analysis that doesn't need snapd: lint, quick-fix suggestions and the
// revision diff shown before signing.
import '../data/models.dart';

/// Resolves a storage path, treating `{placeholder}` segments as any key of a
/// map with typed values.
StorageNode? resolveStoragePath(StorageNode root, String path) {
  StorageNode node = root;
  for (final seg in path.split('.')) {
    if (seg.startsWith('{') && seg.endsWith('}')) {
      if (!node.isMap || node.valuesType == null) return null;
      node = StorageNode(key: seg, kind: _kindFromName(node.valuesType!));
      continue;
    }
    final next = node.children.where((c) => c.key == seg).firstOrNull;
    if (next == null) return null;
    node = next;
  }
  return node;
}

StorageKind _kindFromName(String name) => StorageKind.values.where((k) => k.name == name).firstOrNull ?? StorageKind.any;

/// True when [rulePath] covers [storagePath] (equal, a parent, or a placeholder).
bool ruleCovers(String rulePath, String storagePath) {
  if (rulePath == storagePath || storagePath.startsWith('$rulePath.')) return true;
  final r = rulePath.split('.');
  final s = storagePath.split('.');
  if (r.length > s.length) return false;
  for (var i = 0; i < r.length; i++) {
    if (r[i].startsWith('{') && r[i].endsWith('}')) continue;
    if (r[i] != s[i]) return false;
  }
  return true;
}

enum LintSeverity { error, warning }

class LintIssue {
  const LintIssue({required this.severity, required this.message, this.view, this.request, this.storagePath, this.suggestedLeaf});

  final LintSeverity severity;

  /// Message with `backticked` identifiers.
  final String message;
  final String? view;
  final String? request;
  final String? storagePath;

  /// For a missing storage path: the leaf the quick fix would add.
  final StorageNode? suggestedLeaf;

  bool get isError => severity == LintSeverity.error;
}

List<LintIssue> lintSchema(ConfdbSchema schema) {
  if (schema.builtIn) return const [];
  final issues = <LintIssue>[];
  for (final view in schema.views) {
    if (view.rules.isEmpty) {
      issues.add(LintIssue(severity: LintSeverity.warning, message: '`${view.name}` has no rules, so it exposes nothing', view: view.name));
    }
    final seen = <String>{};
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
      if (!seen.add(rule.request)) {
        issues.add(
          LintIssue(
            severity: LintSeverity.error,
            message: '`${view.name}`: request path `${rule.request}` is used by more than one rule',
            view: view.name,
            request: rule.request,
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
            suggestedLeaf: suggestLeaf(rule.storage),
          ),
        );
      }
    }
  }
  for (final (path, _) in schema.storage.leaves()) {
    final exposed = schema.views.any((v) => v.rules.any((r) => ruleCovers(r.storage, path)));
    if (!exposed) {
      issues.add(
        LintIssue(severity: LintSeverity.warning, message: '`$path` is defined in storage but no view rule exposes it', storagePath: path),
      );
    }
  }
  return issues;
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

  /// View name, or `storage`.
  final String where;
  final String what;
}

/// What a draft changes compared to the revision it is based on.
List<SchemaDiffLine> diffSchemas(ConfdbSchema? base, ConfdbSchema draft) {
  final lines = <SchemaDiffLine>[];
  String rule(ViewRule r) => '${r.request} → ${r.storage}  ·  ${r.access.label}';

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
