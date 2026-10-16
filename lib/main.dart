import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/confdb_repository.dart';
import 'data/fake/fake_repository.dart';
import 'data/snapd/snapd_repository.dart';
import 'data/snapd/transport.dart';

/// Backend, from `--dart-define=CONFDB_BACKEND=…` or the `CONFDB_BACKEND`
/// environment variable:
/// * `fake` (default) – the design's sample data, no snapd needed.
/// * `rest` – snapd's REST API on `/run/snapd.socket`.
/// * `shell` – the `snap` command (`snap debug api`, `pkexec` for writes).
///
/// Fake states: `CONFDB_SCENARIO=slow,disabled,unreachable,no-schemas,load-view-fails,no-custodian`.
ConfdbRepository createRepository() {
  String setting(String name, String fromDefine) => fromDefine.isNotEmpty ? fromDefine : (Platform.environment[name] ?? '');
  final backend = setting('CONFDB_BACKEND', const String.fromEnvironment('CONFDB_BACKEND'));
  final scenario = setting('CONFDB_SCENARIO', const String.fromEnvironment('CONFDB_SCENARIO'));
  return switch (backend) {
    'rest' => SnapdRepository(UnixSocketTransport()),
    'shell' => SnapdRepository(SnapCommandTransport()),
    _ => FakeConfdbRepository(scenario: FakeScenario.parse(scenario)),
  };
}

void main() {
  runApp(ConfdbStudioApp(repository: createRepository()));
}
