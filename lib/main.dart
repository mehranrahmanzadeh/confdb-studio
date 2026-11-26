import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_data.dart';
import 'data/confdb_repository.dart';
import 'data/fake/fake_repository.dart';
import 'data/remote/message_service.dart';
import 'data/remote/remote_models.dart';
import 'data/snapd/snapd_repository.dart';
import 'data/snapd/transport.dart';
import 'state/remote_controller.dart';

/// Backend, from `--dart-define=CONFDB_BACKEND=…` or the `CONFDB_BACKEND`
/// environment variable:
/// * `fake` (default) – the design's sample data, no snapd needed.
/// * `rest` – snapd's REST API on `/run/snapd.socket`.
/// * `shell` – the `snap` command (`snap debug api`, `pkexec` for writes).
///
/// Fake states: `CONFDB_SCENARIO=slow,disabled,unreachable,no-schemas,load-view-fails,no-custodian`.
ConfdbRepository createRepository() {
  final backend = _setting('CONFDB_BACKEND', const String.fromEnvironment('CONFDB_BACKEND'));
  final scenario = _setting('CONFDB_SCENARIO', const String.fromEnvironment('CONFDB_SCENARIO'));
  return switch (backend) {
    'rest' => SnapdRepository(UnixSocketTransport()),
    'shell' => SnapdRepository(SnapCommandTransport()),
    _ => FakeConfdbRepository(scenario: FakeScenario.parse(scenario)),
  };
}

String _setting(String name, String fromDefine) => fromDefine.isNotEmpty ? fromDefine : (Platform.environment[name] ?? '');

/// With a real backend, the Remote tab uses the Store's message service and
/// keeps its state in `remote.json`. `CONFDB_STORE_URL` sets the Store URL
/// until one is saved in the tab's settings. The sample backend gets sample
/// devices.
RemoteController? createRemote(ConfdbRepository repository) {
  if (repository is FakeConfdbRepository) return null;
  final url = _setting('CONFDB_STORE_URL', const String.fromEnvironment('CONFDB_STORE_URL'));
  return RemoteController(
    connect: HttpMessageService.new,
    signer: const SnapRequestSigner(),
    storage: FileRemoteStorage(appDataPath('remote.json')),
    defaults: RemoteSettings(storeUrl: url),
  );
}

void main() {
  final repository = createRepository();
  runApp(ConfdbStudioApp(repository: repository, remote: createRemote(repository)));
}
