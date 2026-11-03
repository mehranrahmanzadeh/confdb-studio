// The gate that keeps the writable integration suite off developer machines.
//
// These tests acknowledge assertions, install snaps and write confdb values on
// the host they run on, so they must only ever run in an environment that gets
// thrown away afterwards: a GitHub-hosted runner, or an LXD *virtual machine*
// (not a container, which shares the host's snapd).
//
// Two things have to agree before anything is mutated:
//
//  1. `--dart-define=SNAPD_IT=true`, so the suite is never picked up by a plain
//     `flutter test`.
//  2. A root-owned marker that [scripts/integration/provision.sh] writes inside
//     the disposable environment, corroborated by an independent signal (the
//     GitHub Actions environment, or "this is a VM"). An unprivileged developer
//     can't create the marker, and the corroboration means a stale marker in a
//     restored home directory or a copied disk image isn't enough on its own.
//
// Missing flag means *skip*. Flag present but the environment isn't disposable
// means *fail*, loudly, before any write — silently skipping there would hide a
// misconfigured CI job.
import 'dart:convert';
import 'dart:io';

/// Whether the caller asked for the integration suite at all.
const integrationEnabled = bool.fromEnvironment('SNAPD_IT');

/// Written by the provisioning script; root-owned and not writable by anyone
/// else, so its presence is a privileged statement about the host.
const markerPath = '/etc/confdb-studio-integration';

/// What kind of throwaway environment the marker claims to describe.
enum DisposableKind {
  /// A GitHub-hosted runner VM.
  github,

  /// An LXD virtual machine (`lxc launch --vm`).
  lxdVm;

  static DisposableKind? parse(String? s) => switch (s) {
    'github' => github,
    'lxd-vm' => lxdVm,
    _ => null,
  };

  String get id => this == github ? 'github' : 'lxd-vm';
}

/// A verified disposable environment.
class DisposableEnvironment {
  const DisposableEnvironment({required this.kind, required this.evidence});

  final DisposableKind kind;

  /// How it was corroborated, for the test log.
  final String evidence;

  @override
  String toString() => '${kind.id} ($evidence)';
}

/// Thrown when the suite is enabled somewhere it must not mutate.
class NotDisposableError extends Error {
  NotDisposableError(this.reason);
  final String reason;

  @override
  String toString() =>
      'Refusing to run the writable snapd integration suite: $reason\n'
      'This suite installs snaps, acknowledges assertions and writes confdb '
      'values, so it only runs on a GitHub-hosted runner or inside a '
      'disposable LXD VM, provisioned by scripts/integration/provision.sh.';
}

DisposableEnvironment? _cached;

/// Verifies the host is disposable, or throws [NotDisposableError].
///
/// Call it before provisioning-dependent set-up *and* again before the first
/// write in a group, so a suite can't mutate a host just because an earlier
/// check happened to run somewhere else.
Future<DisposableEnvironment> requireDisposableEnvironment() async {
  if (_cached != null) return _cached!;

  final marker = File(markerPath);
  if (!marker.existsSync()) {
    throw NotDisposableError('`$markerPath` is missing, so this host was never provisioned for it.');
  }
  await _requireRootOwned(marker);

  final fields = _parseMarker(marker.readAsStringSync());
  final kind = DisposableKind.parse(fields['kind']);
  if (kind == null) {
    throw NotDisposableError('`$markerPath` doesn’t say which kind of environment this is (expected `kind=github` or `kind=lxd-vm`).');
  }

  final evidence = await _corroborate(kind);
  return _cached = DisposableEnvironment(kind: kind, evidence: evidence);
}

/// The marker must be owned by root and writable by nobody else — that's what
/// makes it something an ordinary user can't forge.
Future<void> _requireRootOwned(File marker) async {
  final ProcessResult stat;
  try {
    stat = await Process.run('stat', ['-c', '%u:%a', marker.path]);
  } on ProcessException catch (e) {
    throw NotDisposableError('couldn’t stat `${marker.path}` (${e.message}).');
  }
  if (stat.exitCode != 0) {
    throw NotDisposableError('couldn’t stat `${marker.path}`: ${(stat.stderr as String).trim()}');
  }
  final parts = (stat.stdout as String).trim().split(':');
  if (parts.length != 2) throw NotDisposableError('couldn’t read the ownership of `${marker.path}`.');
  final (uid, mode) = (parts[0], int.tryParse(parts[1], radix: 8) ?? 0777);
  if (uid != '0') {
    throw NotDisposableError('`${marker.path}` is owned by uid $uid, not root, so anyone could have written it.');
  }
  // Group- or world-writable (0o022).
  if (mode & 18 != 0) {
    throw NotDisposableError('`${marker.path}` is writable by non-root (mode ${parts[1]}), so it proves nothing.');
  }
}

Map<String, String> _parseMarker(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (!line.trimLeft().startsWith('#') && line.contains('='))
      line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
};

/// A second, independent signal that this really is the kind of environment the
/// marker claims. The marker alone could survive an image being reused.
Future<String> _corroborate(DisposableKind kind) async {
  switch (kind) {
    case DisposableKind.github:
      final env = Platform.environment;
      if (env['GITHUB_ACTIONS'] != 'true' || env['CI'] != 'true') {
        throw NotDisposableError('the marker says `github`, but GITHUB_ACTIONS/CI aren’t set — this isn’t an Actions runner.');
      }
      // Self-hosted runners are persistent and often sit on someone's machine.
      final runner = env['RUNNER_ENVIRONMENT'];
      if (runner != null && runner != 'github-hosted') {
        throw NotDisposableError('this is a `$runner` runner; only GitHub-hosted runners are disposable enough.');
      }
      return 'GITHUB_ACTIONS, RUNNER_ENVIRONMENT=${runner ?? 'unset'}';

    case DisposableKind.lxdVm:
      final virt = await _virtualization();
      if (virt == null || virt == 'none') {
        throw NotDisposableError(
          'the marker says `lxd-vm`, but `systemd-detect-virt` reports `${virt ?? 'unknown'}` — this is bare metal.',
        );
      }
      // An LXD container shares the host's snapd; only a VM has its own.
      if (await _isContainer()) {
        throw NotDisposableError('this is a container (`$virt`), which shares the host’s snapd. Use `lxc launch --vm`.');
      }
      return 'systemd-detect-virt=$virt';
  }
}

Future<String?> _virtualization() async {
  try {
    // Exits non-zero when there's no virtualization, with "none" on stdout.
    final r = await Process.run('systemd-detect-virt', ['--vm']);
    final out = (r.stdout as String).trim();
    return out.isEmpty ? 'none' : out;
  } on ProcessException {
    return null;
  }
}

Future<bool> _isContainer() async {
  try {
    final r = await Process.run('systemd-detect-virt', ['--container']);
    return r.exitCode == 0 && (r.stdout as String).trim() != 'none';
  } on ProcessException {
    return false;
  }
}
