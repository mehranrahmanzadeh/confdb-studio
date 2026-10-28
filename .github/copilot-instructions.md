# Confdb Studio

Confdb Studio is a Flutter desktop app for snapd's experimental **confdb**.
It lets developers browse and edit values through views, author and sign
schemas, manage snap access, and publish schemas to the Snap Store.

## Architecture

- `lib/data/confdb_repository.dart` defines the data-access contract. All
  screens and controllers use `ConfdbRepository`, not a backend directly.
- `lib/data/fake/` contains the sample-data backend and deterministic scenarios.
  Its writes emulate snapd changes and custodian-hook rejection/rollback.
- `lib/data/snapd/` implements real snapd access and transports:
  `UnixSocketTransport` uses `/run/snapd.socket`; `SnapCommandTransport` uses
  `snap debug api`. Signing uses the host's `snap sign`/`snap keys` keyring.
- `lib/data/store/` handles Snap Store schema operations. Ubuntu One login,
  2FA, and authenticated requests go through the pinned `snapstore_auth` Rust
  dependency via Dart FFI.
- `lib/data/drafts/` stores local schema drafts. Drafts are unsigned
  `snap sign` input, with Studio-specific metadata preserved alongside them.
- `lib/data/models.dart` contains shared data types and error/change status
  types.
- `lib/domain/` holds schema codecs, access analysis, path matching, value
  editing, playground behavior, and Store comparison. Keep this logic
  independent of Flutter widgets.
- `lib/state/` contains app-wide controllers. `AppScope`
  (`lib/state/app_scope.dart`) exposes the repository and controllers through
  `BuildContext` extensions such as `context.repo`, `context.app`,
  `context.staging`, and `context.store`.
- `lib/screens/` is organized by feature; `lib/shell/` owns navigation, shared
  chrome, and the pending-change tray. Routes and route state live in
  `AppController`.
- `lib/widgets/` contains reusable UI pieces; `lib/theme/` contains app and
  design-handoff theme definitions.

## Data and behavior contracts

- Keep all confdb reads and writes behind `ConfdbRepository`. Update every
  implementation and relevant fakes/tests when changing its contract.
- A snapd operation that starts a change returns a `ConfdbChange`. A custodian
  rejection is represented by `ChangeStatus.error` on that change and rolls
  back the write; it is not a transport exception. Transport and permission
  failures are `ConfdbException`s.
- Preserve the distinction between schema assertions, local drafts, and
  Store-registered schemas. Signing and acknowledging uses the snap keyring;
  Store push/register and device acknowledgement have separate operations.
- Data Explorer edits are staged in `StagingController` and applied as one
  snapd change per view. Write-only/secret values must not be exposed in UI
  text or logs.
- Use the domain codec and path/access helpers rather than duplicating schema
  interpretation in screens. Schema assertion formats and snapd hook behavior
  are external contracts; retain concrete behavior and error semantics in
  public API documentation.
- Don't silently convert backend failures into success-shaped values. Follow
  existing error reporting and keep rejected changes distinguishable from
  failed requests.

## Development

- Flutter SDK: `environment.sdk: ^3.13.5` in `pubspec.yaml`; CI uses Flutter
  `3.47.7`. After changing dependency manifests, run `flutter pub get`.
- Run with sample data by default: `flutter run -d linux`.
- Select a backend with `CONFDB_BACKEND` via `--dart-define` or environment:
  `fake` (default), `rest`, or `shell`. `CONFDB_SCENARIO` selects fake states;
  see `FakeScenario.parse` in `lib/data/fake/fake_repository.dart`.
- The Snap Store FFI library is built/staged with
  `./scripts/build_rust_backend.sh` (after dependencies are resolved) for
  running or packaging the app with Store authentication.

## Validation

CI runs:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed lib test
flutter test
```

For focused tests, use `flutter test test/<feature>_test.dart`. Visual tests
render screenshots only when `SCREENSHOTS` is set:

```sh
flutter test test/visual --update-goldens --dart-define=SCREENSHOTS=/abs/dir
```

Integration tests are opt-in and read-only; a view read can trigger a polkit
prompt:

```sh
flutter test test/integration --dart-define=SNAPD_IT=true
```

The design-handoff file `lib/theme/confdb_theme.dart` has an explicit
instruction to preserve its original layout; avoid formatting it as part of
unrelated changes.
