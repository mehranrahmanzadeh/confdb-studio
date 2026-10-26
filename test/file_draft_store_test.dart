import 'dart:io';

import 'package:confdb_studio/data/drafts/file_draft_store.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileDraftStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('drafts'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps a draft\'s aliases across a save/list round trip', () async {
      final store = FileDraftStore(dir: dir);
      final draft = networkDraft.copyWith(
        aliases: {
          'channel-name': const StorageNode(key: 'channel-name', kind: StorageKind.string, choices: ['2.4GHz', '5GHz', 'auto']),
        },
      );

      await store.save(draft);
      final loaded = (await store.list()).singleWhere((s) => s.id == draft.id);

      expect(loaded.aliases.keys, ['channel-name']);
      expect(loaded.aliases['channel-name']!.choices, ['2.4GHz', '5GHz', 'auto']);
    });
  });
}
