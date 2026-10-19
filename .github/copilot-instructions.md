# Confdb Studio

Flutter desktop app (Linux) for snapd's experimental **confdb**: browse/edit
values through views, author and sign schemas, manage which snaps reach which
views, and follow every change.

## Build, test, lint

Requires the Flutter SDK (`environment.sdk: ^3.13.5` in `pubspec.yaml`; CI
pins Flutter `3.47.7`). Run `flutter pub get` after cloning or changing
`pubspec.yaml`.

```sh
flutter analyze                                 # lint/static analysis
dart format --output=none --set-exit-if-changed <file(s)>  # check formatting
flutter test                                    # unit + widget tests
flutter test test/domain_test.dart              # a single test file
flutter test test/domain_test.dart --name "round-trips"     # a single test/group
flutter test test/visual --update-goldens --dart-define=SCREENSHOTS=/abs/dir
                                                 # renders 39 screen states to PNGs
flutter test test/integration --dart-define=SNAPD_IT=true
                                                 # read-only checks against local snapd
                                                 # (a view read may show a polkit prompt)
```

CI (`.github/workflows/ci.yml`) runs `flutter analyze`, a formatting check
over `lib/*.dart` and `test/*.dart` (excluding `lib/theme/confdb_theme.dart`,
see below), and `flutter test`. A separate job renders and diffs screenshots
against the PR's base branch.

Run the app:

```sh
flutter run -d linux                                    # sample/fake data (default)
flutter run -d linux --dart-define=CONFDB_BACKEND=rest   # real snapd on /run/snapd.socket
```

Backend/scenario selection (`lib/main.dart`), via `--dart-define` or env var:
- `CONFDB_BACKEND`: `fake` (default, no snapd needed), `rest` (snapd REST API
  on the Unix socket), `shell` (via the `snap` command).
- `CONFDB_SCENARIO` (fake backend only): `slow`, `disabled`, `unreachable`,
  `no-schemas`, `load-view-fails`, `no-custodian`.

## Architecture

All confdb data access goes through the single abstract interface
`ConfdbRepository` (`lib/data/confdb_repository.dart`) — read this file first
for the full data-access contract (schemas, drafts, views, snap plugs, signing
keys, Snap Store session). Two implementations:

- `FakeConfdbRepository` (`lib/data/fake/`): sample data, writes emulate real
  snapd behavior (e.g. `net-manager`'s change-view hook rejects a psk shorter
  than 8 characters and rolls back; IDs continue from `#1846`).
- `SnapdRepository` (`lib/data/snapd/`) over a `SnapdTransport`:
  - `UnixSocketTransport`: HTTP over `/run/snapd.socket`, sends
    `X-Allow-Interaction` so polkit can prompt for admin auth; writes snapd
    refuses there are retried as root via `pkexec snap debug api`.
  - `SnapCommandTransport`: shells out to `snap debug api`, using `pkexec`
    for writes.
  - Signing uses the `snap sign` / `snap keys` commands (keys live in the
    user's keyring), not an in-app implementation.

Writes that snapd runs as changes return the finished `ConfdbChange`; a
change a custodian rejects comes back with `ChangeStatus.error` rather than
throwing. Transport/permission failures throw `ConfdbException`.

Other layers:
- `lib/domain/`: pure logic over schemas/views — schema codec (assertion ⇄
  model), access rules, path matching, storage editing, the "playground"
  value simulator, template generation. No Flutter/widget dependencies here.
- `lib/state/`: app-wide controllers handed down via `AppScope`
  (`lib/state/app_scope.dart`), an `InheritedWidget`. Access from widgets via
  `BuildContext` extensions: `context.repo`, `context.app`, `context.staging`,
  `context.store` — don't thread the repository/controllers through
  constructors.
- `lib/screens/`: one subdirectory per feature area (access, data, onboarding,
  overview, playground, review, schema_editor, schemas, sign, store).
- `lib/shell/`: the app chrome (nav rail, top bar, pending-change tray,
  snapd status indicator) hosting the screens.
- `lib/app.dart` wires it all together (`ConfdbStudioApp`): owns the
  controllers, listens to `repository.onChanged` to refresh status/accounts,
  and redirects to onboarding when confdb isn't enabled.

## Conventions

- `lib/theme/confdb_theme.dart` is the design handoff's file and is kept in
  its original layout (only secondary colors were changed) — never run
  `dart format` on it; it's explicitly excluded from the CI formatting check
  and the formatter's 140-column width.
- Formatter uses a 140-column page width (`analysis_options.yaml`), not the
  default 80.
- Doc comments on public APIs (especially in `ConfdbRepository` and
  `domain/`) describe real snapd/CLI behavior (hook names, exact commands,
  error semantics) — preserve this level of detail when touching those files.
- Tests live flat under `test/` by feature (e.g. `storage_edit_test.dart`,
  `playground_test.dart`), plus `test/fixtures/` (real assertion JSON),
  `test/visual/` (golden screenshots), and `test/integration/` (opt-in, needs
  a real snapd via `--dart-define=SNAPD_IT=true`).
