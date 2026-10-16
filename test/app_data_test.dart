import 'dart:io';

import 'package:confdb_studio/data/app_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('app_data_test'));
  tearDown(() => home.deleteSync(recursive: true));

  Map<String, String> snapEnv() => {'HOME': home.path, 'SNAP_USER_COMMON': '${home.path}/snap/confdb-studio/common'};

  test('in the snap, files go in SNAP_USER_COMMON', () {
    expect(appDataPath('store.surl', snapEnv()), '${home.path}/snap/confdb-studio/common/store.surl');
    expect(appDataPath('drafts', snapEnv()), '${home.path}/snap/confdb-studio/common/drafts');
  });

  test('outside a snap, files go under XDG_DATA_HOME, or ~/.local/share', () {
    expect(appDataPath('drafts', {'HOME': home.path}), '${home.path}/.local/share/confdb-studio/drafts');
    expect(appDataPath('drafts', {'HOME': home.path, 'XDG_DATA_HOME': '/x'}), '/x/confdb-studio/drafts');
    expect(appDataPath('drafts', {'HOME': home.path, 'SNAP_USER_COMMON': ''}), '${home.path}/.local/share/confdb-studio/drafts');
  });

  test('a login and drafts left in the old place move to SNAP_USER_COMMON', () {
    final old = Directory('${home.path}/.local/share/confdb-studio')..createSync(recursive: true);
    File('${old.path}/store.surl').writeAsStringSync('login');
    File('${old.path}/drafts/acme_network.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final auth = appDataPath('store.surl', snapEnv());
    final drafts = appDataPath('drafts', snapEnv());
    expect(File(auth).readAsStringSync(), 'login');
    expect(File('$drafts/acme_network.json').existsSync(), isTrue);
    expect(File('${old.path}/store.surl').existsSync(), isFalse);
    expect(Directory('${old.path}/drafts').existsSync(), isFalse);
  });

  test('nothing in the new place is overwritten by an old copy', () {
    File('${home.path}/.local/share/confdb-studio/store.surl')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    File('${home.path}/snap/confdb-studio/common/store.surl')
      ..createSync(recursive: true)
      ..writeAsStringSync('new');

    expect(File(appDataPath('store.surl', snapEnv())).readAsStringSync(), 'new');
    expect(File('${home.path}/.local/share/confdb-studio/store.surl').readAsStringSync(), 'old');
  });
}
