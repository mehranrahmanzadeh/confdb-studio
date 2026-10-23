// Parsing, validating and displaying confdb values, and the CLI commands that
// correspond to writes.
import 'dart:convert';

import '../data/models.dart';

const secretMask = '•••';

/// Display form used in tables: enums bare (`5GHz`), strings JSON-quoted.
String displayValue(StorageNode? node, Object? value, {bool quoteStrings = true}) {
  if (value == null) return 'unset';
  if (value is String && (node?.isEnum ?? false)) return value;
  if (value is String && !quoteStrings) return value;
  return const JsonEncoder().convert(value).replaceAll('","', '", "');
}

/// Converts text typed into an editor into the JSON value for [node].
/// Returns null for empty input.
Object? parseInput(StorageNode? node, String input) {
  final kind = node?.kind ?? StorageKind.string;
  final s = input.trim();
  if (s.isEmpty) return null;
  switch (kind) {
    case StorageKind.int:
      return int.parse(s);
    case StorageKind.number:
      return num.parse(s);
    case StorageKind.bool:
      return s == 'true';
    case StorageKind.array:
    case StorageKind.map:
    case StorageKind.any:
      return jsonDecode(s);
    case StorageKind.string:
      return input;
  }
}

/// Inline validation message for an editor, or null when the input is valid.
String? validateValue(StorageNode? node, String input, {ValueHint? hint}) {
  if (node == null) return null;
  final s = input.trim();
  if (s.isEmpty) return 'Enter a value';
  if (hint?.minLength != null && input.length < hint!.minLength!) {
    return 'Must be at least ${hint.minLength} characters';
  }
  switch (node.kind) {
    case StorageKind.int:
      final v = int.tryParse(s);
      if (v == null) return 'Must be a whole number';
      if (node.isEnum && !node.choices.any((c) => int.tryParse(c) == v)) return 'Must be one of ${node.choices.join(', ')}';
      if (node.min != null && v < node.min!) return 'Must be at least ${node.min}';
      if (node.max != null && v > node.max!) return 'Must be at most ${node.max}';
    case StorageKind.number:
      final v = num.tryParse(s);
      if (v == null) return 'Must be a number';
      if (node.isEnum && !node.choices.any((c) => num.tryParse(c) == v)) return 'Must be one of ${node.choices.join(', ')}';
      if (node.min != null && v < node.min!) return 'Must be at least ${node.min}';
      if (node.max != null && v > node.max!) return 'Must be at most ${node.max}';
    case StorageKind.bool:
      if (s != 'true' && s != 'false') return 'Must be true or false';
    case StorageKind.array:
      try {
        if (jsonDecode(s) is! List) return 'Must be a JSON array';
      } on FormatException {
        return 'Must be a JSON array, like ["a", "b"]';
      }
    case StorageKind.map:
    case StorageKind.any:
      try {
        jsonDecode(s);
      } on FormatException {
        return 'Must be valid JSON';
      }
    case StorageKind.string:
      if (node.isEnum && !node.choices.contains(input)) return 'Must be one of ${node.choices.join(', ')}';
      if (node.pattern != null && !RegExp(node.pattern!).hasMatch(input)) {
        return node.pattern == r'^https?://' ? 'Must be an http:// or https:// URL' : 'Must match ${node.pattern}';
      }
  }
  return null;
}

/// Quotes a shell word only when needed.
String shellQuote(String s) {
  if (s.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_./:=@%+,-]+$').hasMatch(s)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}

/// `sudo snap set acme/network/wifi-admin band=5GHz ssid=acme-office-5g`
String snapSetCommand(ViewRef ref, Iterable<(String key, Object? value, bool secret)> values) {
  final args = <String>[];
  final unset = <String>[];
  for (final (key, value, secret) in values) {
    if (value == null) {
      unset.add(key);
    } else if (secret) {
      args.add('$key=<value>');
    } else {
      args.add('$key=${shellQuote(value is String ? value : jsonEncode(value))}');
    }
  }
  final parts = <String>[
    if (args.isNotEmpty) 'sudo snap set ${ref.path} ${args.join(' ')}',
    if (unset.isNotEmpty) 'sudo snap unset ${ref.path} ${unset.join(' ')}',
  ];
  return parts.isEmpty ? 'sudo snap set ${ref.path}' : parts.join(' && ');
}
