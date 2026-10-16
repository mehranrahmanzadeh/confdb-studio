// Read-only checks against the local snapd. Off by default; run with:
//   flutter test test/integration --dart-define=SNAPD_IT=true
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/snapd/snapd_repository.dart';
import 'package:confdb_studio/data/snapd/transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('SNAPD_IT');

void main() {
  for (final transport in <SnapdTransport Function()>[UnixSocketTransport.new, SnapCommandTransport.new]) {
    final t = transport();
    group(t.name, skip: !_enabled, () {
      final repo = SnapdRepository(t);
      tearDownAll(t.close);

      test('system status', () async {
        final s = await repo.systemStatus();
        expect(s.snapdVersion, isNotEmpty);
        // ignore: avoid_print
        print('${t.name}: snapd ${s.snapdVersion}, confdb enabled: ${s.confdbEnabled}');
      });

      test('schemas parse', () async {
        final schemas = await repo.listSchemas();
        // ignore: avoid_print
        print('${t.name}: ${schemas.map((s) => '${s.id.path} (${s.views.length} views, built-in: ${s.builtIn})').join(', ')}');
      });

      test('snaps and connections', () async {
        final snaps = await repo.listSnaps();
        // ignore: avoid_print
        print('${t.name}: ${snaps.length} snaps with confdb plugs');
      });

      test('reading a view reports permission problems as ConfdbException', () async {
        final schemas = await repo.listSchemas();
        final s = schemas.where((s) => s.views.isNotEmpty).firstOrNull;
        if (s == null) return;
        try {
          final snap = await repo.readView(s.id.view(s.views.first.name));
          // ignore: avoid_print
          print('${t.name}: read ${snap.entries.length} entries from ${snap.ref.path}');
        } on ConfdbException catch (e) {
          // ignore: avoid_print
          print('${t.name}: ${e.kind.name}: $e');
          expect(e.kind, anyOf(ConfdbErrorKind.permissionDenied, ConfdbErrorKind.notFound, ConfdbErrorKind.other));
        }
      });
    });
  }
}
