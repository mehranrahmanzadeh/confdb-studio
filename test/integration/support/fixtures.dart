// Shared set-up for the integration suites: one [SnapdRepository] per
// transport, pointed at the snapd running on this machine.
import 'dart:io';

import 'package:confdb_studio/data/drafts/file_draft_store.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:confdb_studio/data/snapd/transport.dart';

import 'environment.dart';

/// The schema snapd compiles in. It needs no assertion, so it's there on any
/// snapd new enough to support confdb, which makes it a stable fixture for
/// everything that only reads *schemas* (as opposed to values).
const builtInSchema = SchemaId('system', 'validation-sets');

/// Upstream's test fixture, acknowledged by `provision.sh --test-keys`.
const fixtureSchema = SchemaId('developer1', 'network');
const fixtureView = ViewRef('developer1', 'network', 'wifi-admin');
const fixtureCustodian = 'confdb-studio-custodian';

/// Every concrete path the custodian suite writes, so it can put the fixture
/// back the way it found it between tests.
const fixtureWritablePaths = ['ssid', 'password', 'private.team', 'private.count', 'private.on'];

/// Whether the fixtures that need a test-keys snapd were provisioned.
const testKeysEnabled = bool.fromEnvironment('SNAPD_IT_TEST_KEYS');

/// A transport, named, plus how to build it.
class TransportCase {
  const TransportCase(this.name, this.create);
  final String name;
  final SnapdTransport Function() create;
}

/// Both transports the app ships. They take different code paths to snapd
/// (socket vs. subprocess), so repository behaviour is checked against each.
List<TransportCase> get transportCases => [
  const TransportCase('snapd REST', UnixSocketTransport.new),
  TransportCase('snap command', _snapCommandTransport),
];

/// How privileged writes are run by the `snap debug api` transport.
///
/// `pkexec`, the app's default, can't work here: nobody can answer a polkit
/// prompt in a headless environment. The suite runs as root (see
/// [integrationSkipReason]), so there's nothing to elevate with.
SnapdTransport _snapCommandTransport() => SnapCommandTransport(elevate: const []);

bool get isRoot => _uid == 0;
int get _uid => int.parse((Process.runSync('id', ['-u']).stdout as String).trim());

/// A repository on [t], with drafts kept in a throwaway directory so the suite
/// never touches a real `~/.local/share` on the machine it runs on.
SnapdRepository repositoryFor(SnapdTransport t, Directory draftDir) => SnapdRepository(t, drafts: FileDraftStore(dir: draftDir));

/// Guards a whole suite: skips when the suite wasn't asked for, and fails
/// loudly when it was asked for somewhere it must not mutate, or where it
/// can't work.
///
/// Returns the skip reason for `group(skip: …)`, or null to run.
Future<String?> integrationSkipReason() async {
  if (!integrationEnabled) {
    return 'Off by default. Run with --dart-define=SNAPD_IT=true on a provisioned, disposable machine.';
  }
  // Throws rather than skips: an enabled suite that silently does nothing
  // would make a misconfigured CI job look green.
  await requireDisposableEnvironment();

  // snapd only accepts confdb reads and writes from an administrator, and the
  // `snap debug api` transport only elevates writes — so reads through it need
  // the process itself to be root. Say so now rather than failing per test.
  if (!isRoot) {
    throw StateError(
      'The integration suite must run as root: snapd only lets an administrator '
      'read or write confdb values, and nobody can answer a polkit prompt in a '
      'headless environment. Run it with `sudo -E env "PATH=\$PATH" flutter test …`.',
    );
  }
  return null;
}
