// Request and storage paths in view rules, parsed the way snapd does
// (confdb/confdb.go): dotted keys, `{placeholder}` keys, `[0]` and `[{n}]`
// list accessors, and `[.field={param}]` field filters at the end of a key.
import 'package:flutter/foundation.dart';

enum SegmentKind { key, keyPlaceholder, listIndex, indexPlaceholder }

/// `[.field={param}]`: keeps only map values whose [field] equals [param].
@immutable
class FieldFilter {
  const FieldFilter(this.field, this.param);
  final String field;
  final String param;

  @override
  String toString() => '[.$field={$param}]';
}

@immutable
class PathSegment {
  const PathSegment(this.kind, this.name, [this.filters = const []]);

  final SegmentKind kind;

  /// Key, placeholder name, or index digits.
  final String name;
  final List<FieldFilter> filters;

  bool get isPlaceholder => kind == SegmentKind.keyPlaceholder || kind == SegmentKind.indexPlaceholder;
  bool get isIndex => kind == SegmentKind.listIndex || kind == SegmentKind.indexPlaceholder;

  /// The segment without its filters: `key`, `{key}`, `[0]` or `[{n}]`.
  @override
  String toString() => switch (kind) {
    SegmentKind.key => name,
    SegmentKind.keyPlaceholder => '{$name}',
    SegmentKind.listIndex => '[$name]',
    SegmentKind.indexPlaceholder => '[{$name}]',
  };
}

class PathFormatException implements Exception {
  const PathFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// snapd's subkey format, used for keys, placeholder, field and parameter names.
final _subkey = RegExp(r'^[a-z](?:-?[a-z0-9])*$');
final _digits = RegExp(r'^[0-9]+$');
final _filter = RegExp(r'^\.([^=]*)=\{([^}]*)\}$');

/// Parses a request or storage path; throws [PathFormatException] with
/// snapd-like wording when it isn't valid.
List<PathSegment> parsePath(String path) {
  if (path.isEmpty) throw const PathFormatException('the path is empty');
  final segs = <PathSegment>[];
  var i = 0;
  while (true) {
    late final PathSegment seg;
    if (path[i] == '[') {
      final end = path.indexOf(']', i);
      if (end < 0) throw PathFormatException('`${path.substring(i)}` has no closing `]`');
      final inner = path.substring(i + 1, end);
      if (_digits.hasMatch(inner)) {
        seg = PathSegment(SegmentKind.listIndex, '${int.parse(inner)}');
      } else if (inner.startsWith('{') && inner.endsWith('}') && _subkey.hasMatch(inner.substring(1, inner.length - 1))) {
        seg = PathSegment(SegmentKind.indexPlaceholder, inner.substring(1, inner.length - 1));
      } else {
        throw PathFormatException('`[$inner]` must be a list index like `[0]` or an index placeholder like `[{n}]`');
      }
      i = end + 1;
    } else {
      var end = i;
      while (end < path.length && path[end] != '.' && path[end] != '[') {
        end++;
      }
      final text = path.substring(i, end);
      if (text.isEmpty) throw const PathFormatException('it has an empty key');
      if (text.startsWith('{') && text.endsWith('}')) {
        final name = text.substring(1, text.length - 1);
        if (!_subkey.hasMatch(name)) throw PathFormatException('placeholder `$text` must be lowercase letters, digits and dashes');
        seg = PathSegment(SegmentKind.keyPlaceholder, name);
      } else {
        if (!_subkey.hasMatch(text)) {
          throw PathFormatException('key `$text` must start with a letter and use lowercase letters, digits and single dashes');
        }
        seg = PathSegment(SegmentKind.key, text);
      }
      i = end;
    }

    final filters = <FieldFilter>[];
    while (i + 1 < path.length && path[i] == '[' && path[i + 1] == '.') {
      final end = path.indexOf(']', i);
      final m = end < 0 ? null : _filter.firstMatch(path.substring(i + 1, end));
      if (m == null) throw const PathFormatException('a field filter must look like `[.field={param}]`');
      final (field, param) = (m[1]!, m[2]!);
      if (!_subkey.hasMatch(field) || !_subkey.hasMatch(param)) {
        throw PathFormatException('in `[.$field={$param}]`, the field and parameter must be lowercase letters, digits and dashes');
      }
      if (filters.any((f) => f.field == field)) throw PathFormatException('`$seg` filters on `$field` twice');
      filters.add(FieldFilter(field, param));
      i = end + 1;
    }
    segs.add(filters.isEmpty ? seg : PathSegment(seg.kind, seg.name, filters));

    if (i == path.length) return segs;
    if (path[i] == '.') {
      i++;
      if (i == path.length || path[i] == '.' || path[i] == '[') throw const PathFormatException('it has an empty key');
      continue;
    }
    if (filters.isNotEmpty) throw const PathFormatException('field filters must end a key, and only a key can follow them');
    if (path[i] != '[') throw PathFormatException('expected `.` or `[` before `${path.substring(i)}`');
  }
}

/// [parsePath], or null when the path isn't valid.
List<PathSegment>? tryParsePath(String path) {
  try {
    return parsePath(path);
  } on PathFormatException {
    return null;
  }
}

/// Joins segments back into a path; field filters only when [filters].
String joinPath(Iterable<PathSegment> segs, {bool filters = false}) {
  final b = StringBuffer();
  for (final s in segs) {
    if (!s.isIndex && b.isNotEmpty) b.write('.');
    b.write(s);
    if (filters) s.filters.forEach(b.write);
  }
  return b.toString();
}

bool hasPlaceholders(String path) => tryParsePath(path)?.any((s) => s.isPlaceholder) ?? false;

/// A problem with a rule's paths, in snapd's terms. Message uses `backticks`.
typedef PathProblem = ({bool isError, String message});

/// Checks a rule's paths the way snapd does when it parses a view: syntax,
/// no literal indexes in the request, and matching placeholders.
List<PathProblem> checkRulePaths(String request, String storage) {
  final problems = <PathProblem>[];
  List<PathSegment>? parse(String what, String path) {
    try {
      return parsePath(path);
    } on PathFormatException catch (e) {
      problems.add((isError: true, message: '$what path `$path` is invalid: ${e.message}'));
      return null;
    }
  }

  final req = parse('request', request);
  final sto = parse('storage', storage);
  if (req == null || sto == null) return problems;

  if (req.any((s) => s.kind == SegmentKind.listIndex)) {
    problems.add((isError: true, message: 'request paths can’t use literal indexes like `[0]`, only index placeholders like `[{n}]`'));
  }
  if (req.any((s) => s.filters.isNotEmpty)) {
    problems.add((isError: false, message: 'field filters only apply in the storage path; snapd ignores them in `$request`'));
  }

  for (final (kind, label) in [(SegmentKind.keyPlaceholder, 'key'), (SegmentKind.indexPlaceholder, 'index')]) {
    final inReq = [
      for (final s in req)
        if (s.kind == kind) s.name,
    ];
    final inSto = [
      for (final s in sto)
        if (s.kind == kind) s.name,
    ];
    final dup = inReq.where((n) => inReq.where((m) => m == n).length > 1).toSet();
    for (final n in dup) {
      problems.add((isError: true, message: 'request `$request` uses the $label placeholder `$n` more than once'));
    }
    final missing = inReq.where((n) => !inSto.contains(n)).toSet();
    for (final n in missing) {
      problems.add((isError: true, message: 'placeholder `$n` in request `$request` is missing from storage `$storage`'));
    }
    if (missing.isEmpty && dup.isEmpty && inReq.length != inSto.length) {
      problems.add((isError: true, message: 'request `$request` and storage `$storage` have different $label placeholders'));
    }
  }
  final keyNames = {
    for (final s in [...req, ...sto])
      if (s.kind == SegmentKind.keyPlaceholder) s.name,
  };
  final indexNames = {
    for (final s in [...req, ...sto])
      if (s.kind == SegmentKind.indexPlaceholder) s.name,
  };
  for (final n in keyNames.intersection(indexNames)) {
    problems.add((isError: true, message: '`$n` is used as both a key and an index placeholder'));
  }
  return problems;
}

/// Parameters named by field filters in [storage], in order.
List<String> filterParams(String storage) => [
  for (final s in tryParsePath(storage) ?? const <PathSegment>[])
    for (final f in s.filters) f.param,
];

/// The field filters on [path]'s last segment, where the editor attaches
/// them (e.g. `actuators.{act}[.mode={mode}]`).
List<FieldFilter> lastSegmentFilters(String path) => tryParsePath(path)?.lastOrNull?.filters ?? const [];

/// [path] with its last segment's field filters replaced by [filters]. Other
/// segments' own filters, if any, are kept untouched.
String withLastSegmentFilters(String path, List<FieldFilter> filters) {
  final segs = tryParsePath(path);
  if (segs == null || segs.isEmpty) return path;
  return joinPath([
    for (var i = 0; i < segs.length; i++)
      if (i == segs.length - 1) PathSegment(segs[i].kind, segs[i].name, filters) else segs[i],
  ], filters: true);
}

/// Matches a concrete path (say `accelerometers.x`) against a rule's request
/// (`accelerometers.{sensor}`). Returns the placeholder values and what's left
/// of [concrete] past the rule, or null when it doesn't match.
({Map<String, String> bindings, List<PathSegment> rest})? matchPath(String pattern, String concrete) {
  final p = tryParsePath(pattern);
  final c = tryParsePath(concrete);
  if (p == null || c == null || c.length < p.length) return null;
  final bindings = <String, String>{};
  for (var i = 0; i < p.length; i++) {
    final (ps, cs) = (p[i], c[i]);
    if (ps.toString() == cs.toString()) continue;
    if (ps.kind == SegmentKind.keyPlaceholder && cs.kind == SegmentKind.key ||
        ps.kind == SegmentKind.indexPlaceholder && cs.kind == SegmentKind.listIndex) {
      bindings[ps.name] = cs.name;
      continue;
    }
    return null;
  }
  return (bindings: bindings, rest: c.sublist(p.length));
}

/// [pattern] with its placeholders replaced by [bindings] (unbound ones stay),
/// field filters dropped and [rest] appended.
String fillPath(String pattern, Map<String, String> bindings, [List<PathSegment> rest = const []]) {
  final segs = tryParsePath(pattern);
  if (segs == null) return pattern;
  return joinPath([
    for (final s in segs)
      switch (s.kind) {
        SegmentKind.keyPlaceholder when bindings[s.name] != null => PathSegment(SegmentKind.key, bindings[s.name]!),
        SegmentKind.indexPlaceholder when bindings[s.name] != null => PathSegment(SegmentKind.listIndex, bindings[s.name]!),
        _ => PathSegment(s.kind, s.name),
      },
    ...rest,
  ]);
}

/// Placeholder names in [path], in order.
List<String> placeholdersOf(String path) => [
  for (final s in tryParsePath(path) ?? const <PathSegment>[])
    if (s.isPlaceholder) s.name,
];

/// Looks [path] up in a decoded value. A placeholder stops the walk: the
/// result is everything it could stand for (the map or list at that point).
(bool, Object?) lookupValue(Object? root, String path) {
  if (root is Map && root.containsKey(path)) return (true, root[path]);
  final segs = tryParsePath(path);
  if (segs == null) return (false, null);
  Object? node = root;
  for (final s in segs) {
    if (s.isPlaceholder) return (node is Map || node is List, node);
    if (s.kind == SegmentKind.listIndex) {
      final i = int.parse(s.name);
      if (node is List && i < node.length) {
        node = node[i];
        continue;
      }
      return (false, null);
    }
    if (node is Map && node.containsKey(s.name)) {
      node = node[s.name];
      continue;
    }
    return (false, null);
  }
  return (true, node);
}

/// Whether [value] can stand in for the placeholder [name] of [path]: a key
/// for `{name}`, digits for `[{name}]`.
bool isValidPlaceholderValue(String path, String name, String value) {
  final seg = tryParsePath(path)?.where((s) => s.isPlaceholder && s.name == name).firstOrNull;
  if (seg == null) return false;
  return seg.kind == SegmentKind.indexPlaceholder ? _digits.hasMatch(value) : _subkey.hasMatch(value);
}

/// The fixed part of [path] before its first placeholder (`accelerometers`
/// for `accelerometers.{sensor}`); empty when it starts with one.
String fixedPrefix(String path) {
  final segs = tryParsePath(path);
  if (segs == null) return path;
  return joinPath(segs.takeWhile((s) => !s.isPlaceholder));
}

bool placeholderIsIndex(String path, String name) =>
    tryParsePath(path)?.any((s) => s.kind == SegmentKind.indexPlaceholder && s.name == name) ?? false;

/// How snapd matches a request against a rule's request (`viewRule.match`):
/// the request must be the rule's request or a prefix of it, never longer.
/// Returns the placeholder values bound by the request and the rule's
/// unmatched suffix, or null. An empty request matches every rule.
({Map<String, String> bindings, List<PathSegment> suffix})? matchRequest(String ruleRequest, String request) {
  final rule = tryParsePath(ruleRequest);
  final req = request.isEmpty ? const <PathSegment>[] : tryParsePath(request);
  if (rule == null || req == null || req.length > rule.length) return null;
  final bindings = <String, String>{};
  for (var i = 0; i < req.length; i++) {
    final (r, q) = (rule[i], req[i]);
    if (r.toString() == q.toString()) continue;
    if (r.kind == SegmentKind.keyPlaceholder && q.kind == SegmentKind.key ||
        r.kind == SegmentKind.indexPlaceholder && q.kind == SegmentKind.listIndex) {
      bindings[r.name] = q.name;
      continue;
    }
    return null;
  }
  return (bindings: bindings, suffix: rule.sublist(req.length));
}
