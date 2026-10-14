# Confdb Studio

Flutter desktop app (Ubuntu, Material 3, dark only) for snapd's experimental
**confdb**: browse and edit values through views, author and sign schemas,
manage which snaps reach which views, and follow every change. Built from the
design handoff in `HANDOFF.md` and `design/`.

## Run

```sh
flutter run -d linux                                  # sample data (default)
flutter run -d linux --dart-define=CONFDB_BACKEND=rest   # snapd on /run/snapd.socket
flutter run -d linux --dart-define=CONFDB_BACKEND=shell  # the snap command
```

`CONFDB_BACKEND` and `CONFDB_SCENARIO` can also be set as environment variables
for a built binary. Building for Linux needs
`sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`.

Sample-data scenarios (comma-separated `CONFDB_SCENARIO`) reach every state in
the designs:

| Flag | Shows |
|---|---|
| `disabled` | Onboarding: confdb not enabled (starts with no schemas) |
| `unreachable` | Schemas: "Couldn't load schemas" (first load only; Retry works) |
| `no-schemas`, `no-changes` | Schemas and Activity empty states |
| `load-view-fails` | Data explorer: load-view hook failed (first read only) |
| `slow` | 3 s latency, for the loading states |
| `no-keys` | Sign dialog: no signing keys, with setup commands and Refresh keys |
| `no-custodian` | telemetry-agent's custodian plug starts disconnected: "How to connect?" guide |
| `logged-out` | snapcraft not logged in: warning on the rail's account button |

## Backends

All data goes through `ConfdbRepository` (`lib/data/confdb_repository.dart`):

- `FakeConfdbRepository`: the handoff's sample data. Writes behave like snapd.
  `net-manager`'s change-view hook rejects a psk shorter than 8 characters and
  the change rolls back; observers are notified; IDs continue from #1846.
- `SnapdRepository` over a `SnapdTransport`:
  - `UnixSocketTransport`: HTTP on `/run/snapd.socket`, with
    `X-Allow-Interaction` so polkit can ask for admin authentication.
    Writes snapd refuses there (installing assertions accepts only root) are
    retried as root through `pkexec snap debug api`.
  - `SnapCommandTransport`: `snap debug api`, with `pkexec` for writes.

  Signing uses `snap sign` and `snap keys` (keys live in the user's keyring).
  Drafts are a Studio concept, stored by `FileDraftStore` as `snap sign` input in
  `~/.local/share/confdb-studio/drafts/`.

Checked against snapd 2.77.1 (read-only): `system-info` (the `confdb` feature
flag; reading `system` conf needs root), confdb-schema assertions (including the
built-in `system/validation-sets`, with aliases and nested `content` rules),
`connections?interface=confdb` (slot `snapd:confdb`), changes, and view-read
errors. The confdb **write** and **async read** payloads, and ack/sign, follow
snapd's API conventions but weren't exercised against a live custodian.

Secret storage (`"visibility": "secret"`, snapd 2.76+): the schema editor's
storage dialog has a Secret checkbox, and warns when the connected snapd is
older. Decoding enforces snapd's rules: no secrets inside alias types, and an
entry's alternatives are either all secret or none. Secret values show as hidden
in the data explorer and the playground, since snapd leaves them out of
non-admin reads. The fake backend reports snapd 2.77 and marks `wifi.psk` secret.

Deleting: snapd has no way to remove an acknowledged confdb-schema from a
device (assertions are only ever superseded by a higher revision), so the app
offers none. A view is removed by deleting it in the editor and signing the next
revision; its stored values stay in storage. Local drafts can be discarded from
the Schemas list.

Limits of the real backend: it doesn't report a snap's declared hooks, acknowledging is
synchronous (no change to link to), and it doesn't know the developer account ID
(it uses the `id` from `snapcraft whoami` when logged in, else
`CONFDB_ACCOUNT`, else onboarding asks for it). The rail's account button shows
the snapcraft login and warns when it's missing, since registering signing keys
needs it.

## Layout

```
lib/
  theme/confdb_theme.dart   handoff theme; secondary changed from aubergine to slate
  theme/app_theme.dart      TextTheme weights, focus rings, StatusColors/mono helpers
  data/                     models, repository interface, fake, snapd, drafts
  domain/                   pure logic: storage/assertion codec, lint + quick fix,
                            revision diff, hook plan, access diagnosis, playground
  state/                    routes, staged edits, AppScope
  shell/                    rail (with account and snapd status), pending tray, route → screen
  widgets/                  StatusBadge, CliDisclosure, chips, fields, timeline…
  screens/                  one folder per screen (7.1–7.11)
```

Every color comes from `ColorScheme` or `StatusColors`. Ubuntu Sans and Ubuntu
Sans Mono are bundled as static weights cut from the Ubuntu variable fonts, plus
a tiny DejaVu Sans Mono subset as fallback for `→`, which the Ubuntu fonts lack.
Below 1200 px wide the rail shows icons only and screens stack their panes.

## Design → code

| Design | Code |
|---|---|
| Rail, Tray (TopBar dropped; snapd status sits at the rail's bottom) | `shell/app_rail.dart`, `shell/snapd_status.dart`, `shell/pending_tray.dart` |
| Badge, Cli | `widgets/status_badge.dart`, `widgets/cli_disclosure.dart` |
| 7.1 Onboarding (+Choose) | `screens/onboarding/` |
| 7.2 Main (+Rev5, Compact) | `screens/overview/` |
| 7.3 SchemasList (+Empty, Loading, Error) | `screens/schemas/` |
| 7.4 SchemaEditor (+JSON, Fixed) | `screens/schema_editor/` |
| 7.5 SignDialog (+Progress) | `screens/sign/` |
| 7.6 DataExplorer (+Psk, Empty, Error, Compact; Raw storage and the Edit switch were dropped) | `screens/data/` |
| 7.7 ReviewSheet, DataExplorer-Applied/-Rejected | `screens/review/`, `screens/data/` |
| 7.8 Playground (+Denied) | `screens/playground/` |
| 7.9 Access (+Pass, Disconnect) | `screens/access/` |
| 7.10 Activity (+Empty, Loading), 7.11 ChangeDetail (+1845) | `screens/activity/` |

Where the app departs from the mockups, it follows the data. Lint flags
`acme/network`'s unexposed `proxy.https` on the Overview too, and every
store-installed snap gets the Publisher-signed badge. `Main.dc.html` defines an
"attention" list that its markup never renders, so it isn't built.

## Tests

```sh
flutter analyze
flutter test                                    # unit + widget tests
flutter test test/visual --update-goldens --dart-define=SCREENSHOTS=/abs/dir
                                                # renders 39 screen states to PNGs
flutter test test/integration --dart-define=SNAPD_IT=true
                                                # read-only checks against local snapd
                                                # (a view read may show a polkit prompt)
```
