import 'dart:convert';
import 'dart:io';

import '../../domain/schema_codec.dart';
import '../app_data.dart';
import '../models.dart';

/// Drafts live on disk as `snap sign` input plus a few Studio fields, in
/// `drafts/<account>_<name>.json` under [appDataDir].
class FileDraftStore {
  FileDraftStore({Directory? dir}) : dir = dir ?? _defaultDir();

  final Directory dir;

  static Directory _defaultDir() => Directory(appDataPath('drafts'));

  File _file(SchemaId id) => File('${dir.path}/${id.account}_${id.name}.json');

  Future<List<ConfdbSchema>> list() async {
    if (!await dir.exists()) return const [];
    final drafts = <ConfdbSchema>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        drafts.add(_decode(jsonDecode(await f.readAsString()) as Map));
      } on Object {
        // A broken draft file shouldn't hide the others.
      }
    }
    return drafts;
  }

  Future<void> save(ConfdbSchema draft) async {
    await dir.create(recursive: true);
    final json = {
      ...signInput(draft, revision: (draft.baseRevision ?? 0) + 1, timestamp: DateTime.now()),
      'x-studio-base-revision': draft.baseRevision,
      'x-studio-added-in-draft': draft.addedInDraft.toList(),
    };
    final tmp = File('${_file(draft.id).path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    await tmp.rename(_file(draft.id).path);
  }

  Future<void> discard(SchemaId id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
  }

  ConfdbSchema _decode(Map json) {
    final s = schemaFromHeaders(json, jsonDecode(json['body'] as String));
    // The `revision` header is the one signing will create; a draft has none yet.
    return ConfdbSchema(
      id: s.id,
      summary: s.summary,
      views: s.views,
      storage: s.storage,
      isDraft: true,
      baseRevision: json['x-studio-base-revision'] as int?,
      addedInDraft: {for (final p in (json['x-studio-added-in-draft'] as List? ?? const [])) '$p'},
    );
  }
}
