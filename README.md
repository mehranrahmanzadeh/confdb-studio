# Confdb Studio

Flutter desktop app for snapd's experimental
**confdb**: browse and edit values through views, author and sign schemas,
manage which snaps reach which views, and follow every change.

## Screenshots

### Overview

![Confdb Studio overview](docs/screenshots/overview.png)

### Schemas

![Confdb schemas list](docs/screenshots/schemas.png)

### Schema Editor

![Confdb schema editor](docs/screenshots/schema_editor.png)

### Data Explorer

![Confdb data explorer](docs/screenshots/data.png)

### Access

![Confdb access management](docs/screenshots/access.png)

## Run

```sh
flutter run -d linux                                  # sample data (default)
flutter run -d linux --dart-define=CONFDB_BACKEND=rest   # snapd on /run/snapd.socket
```

## Snap

With Snapcraft installed and its build environment configured, build and install
the snap from the repository root (amd64 example):

```sh
snapcraft pack
sudo snap install --dangerous --classic ./confdb-studio_0.0.1_amd64.snap
snap run confdb-studio
```

## Backends

All data goes through `ConfdbRepository` (`lib/data/confdb_repository.dart`):

- `FakeConfdbRepository`: the sample data. Writes behave like snapd.
  `net-manager`'s change-view hook rejects a psk shorter than 8 characters and
  the change rolls back; observers are notified; IDs continue from #1846.
- `SnapdRepository` over a `SnapdTransport`:
  - `UnixSocketTransport`: HTTP on `/run/snapd.socket`, with
    `X-Allow-Interaction` so polkit can ask for admin authentication.
    Writes snapd refuses there (installing assertions accepts only root) are
    retried as root through `pkexec snap debug api`.
  - `SnapCommandTransport`: `snap debug api`, with `pkexec` for writes. The
    command prefix is configurable (`elevate:`), so headless callers can use
    `['sudo', '-n']`, or nothing at all when already root.

  Signing uses `snap sign` and `snap keys` (keys live in the user's keyring).

The Snap Store confdb-schemas API (`SnapStoreClient`,
`lib/data/store/snap_store_client.dart`) talks Ubuntu One SSO login, 2FA, and
macaroon-signed requests through
[`snapstore-auth`](https://github.com/ogra1/snapstore-auth), a native Rust
backend pulled in as a pinned git dependency (see `pubspec.yaml`, not
vendored in this repo) and bound from Dart over `dart:ffi`
(`lib/data/store/snapstore_auth_client.dart`). Build it with
`scripts/build_rust_backend.sh` before `flutter run`/packaging; the saved
login lives in `store.json` under the app data dir.

## Tests

```sh
flutter analyze
flutter test                                    # unit + widget tests
flutter test test/visual --update-goldens --dart-define=SCREENSHOTS=/abs/dir
                                                # renders 39 screen states to PNGs
```

### Integration tests against a real snapd

`test/integration/` checks `ConfdbRepository` against a real snapd over both
transports. The suites are off unless `--dart-define=SNAPD_IT=true` is passed,
and the writable ones refuse to run anywhere that isn't disposable — see
[`scripts/integration/`](scripts/integration) and
[the safety gate](test/integration/support/environment.dart).

| Suite | Needs | What it covers |
| --- | --- | --- |
| `snapd_readonly_test.dart` | any snapd | Smoke test; safe on your own machine (a view read may show a polkit prompt) |
| `snapd_builtin_test.dart` | a disposable machine | Schema parsing, snap/connection listing, error semantics, drafts — against the `system/validation-sets` schema snapd compiles in, so no credentials or signed fixtures are needed |
| `snapd_custodian_test.dart` | a disposable machine with the signed fixture and custodian | Reads, writes, unsets, custodian rejection and rollback, write-only values, connect/disconnect |

Both suites use stock snapd. The custodian suite acknowledges the committed
public `confdb-studio-integration.assert` chain, signed with a Store-registered
key, and installs a local fixture snap. It does not build snapd, alter its trust
roots, import private keys, or publish anything to the Store. The test account
is read from the signed assertion rather than configured separately.

Run everything in a throwaway LXD **virtual machine** (not a container, which
would share your own snapd):

```sh
scripts/integration/run-lxd.sh              # stock snapd
scripts/integration/run-lxd.sh --custodian  # + signed fixture and custodian
```

The `snapd integration` GitHub workflow runs both suites on pull requests, main
pushes, and nightly. Manual runs can skip the custodian suite. No GitHub signing
secret or account/key variables are needed, including for fork PRs.
To run the suites by hand on a machine you've already provisioned:

```sh
sudo scripts/integration/provision.sh --kind lxd-vm [--custodian]
sudo -E env "PATH=$PATH" flutter test test/integration \
  --dart-define=SNAPD_IT=true [--dart-define=SNAPD_IT_CUSTODIAN=true]
```

They run as root because snapd only lets an administrator read or write confdb
values and nothing can answer a polkit prompt in a headless environment.

#### Regenerating the public signed fixture

After changing `scripts/integration/fixtures/confdb-studio-integration.json`,
sign it locally using a key already registered with the Snap Store. Install
`jq` if needed, find the key SHA with `snap keys`, then run **without sudo**:

```sh
TEST_ACCOUNT_ID='<account-id>' TEST_KEY_SHA3='<key-sha3-384>' \
  bash scripts/integration/sign-fixture.sh
```

The helper checks the key belongs to the account, signs through the existing
local keyring, and includes the public account/key assertion chain. Review and
commit the generated `.assert` file with the JSON template. The normal unit
suite checks that they match; disposable integration runs validate the
signature chain through snapd. Never commit a private key or expose one to
PR-controlled code.
