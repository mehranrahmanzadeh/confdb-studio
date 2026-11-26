import 'dart:convert';

import '../../data/confdb_repository.dart';
import '../../data/models.dart';
import '../../domain/remote.dart';
import '../../state/store_controller.dart';

/// Every schema Studio can see (acknowledged here, in the Store, or a local
/// draft), to suggest views and keys and to tell secret values apart.
class KnownSchemas {
  const KnownSchemas(this.byId);
  final Map<SchemaId, ConfdbSchema> byId;

  ConfdbSchema? schemaOf(String view) {
    try {
      return byId[ViewRef.parse(view).schemaId];
    } on FormatException {
      return null;
    }
  }

  /// `account/schema/view` of every view.
  List<String> get views => [
    for (final s in byId.values)
      for (final v in s.views) '${s.id.account}/${s.id.name}/${v.name}',
  ]..sort();

  ValueMasker masker(String view) {
    final schema = schemaOf(view);
    final name = view.split('/').last;
    return ValueMasker(schema?.view(name) == null ? null : schema, name);
  }
}

Future<KnownSchemas> loadKnownSchemas(ConfdbRepository repo, StoreController store) async {
  final byId = <SchemaId, ConfdbSchema>{};
  Future<List<ConfdbSchema>> safe(Future<List<ConfdbSchema>> f) => f.catchError((_) => <ConfdbSchema>[]);
  final drafts = await safe(repo.listDrafts());
  final local = await safe(repo.listSchemas());
  // Later wins: drafts, then the Store's, then what's acknowledged here.
  for (final s in [...drafts, ...?store.schemas, ...local]) {
    byId[s.id] = s;
  }
  return KnownSchemas(byId);
}

/// Hides secret values in what devices answer. Without the schema nothing
/// can be told apart, so everything stays hidden unless revealed.
class ValueMasker {
  const ValueMasker(this.schema, this.view);
  final ConfdbSchema? schema;
  final String view;

  static const mask = '••••••';

  bool get knowsSchema => schema != null;

  bool isSecret(String path) => schema != null && isSecretRequestPath(schema!, view, path);

  String show(String path, Object? value, {bool revealUnknown = false}) {
    if (isSecret(path) || (!knowsSchema && !revealUnknown)) return mask;
    return value is String ? value : jsonEncode(value);
  }
}
