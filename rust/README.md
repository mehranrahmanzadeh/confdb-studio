# snapstore-auth (vendored)

This crate is vendored from `ubuntu-core-model-builder`'s Rust backend for
interactive Ubuntu One SSO login + macaroon handling for the Snap Store
(commit `805d9cd2d55465111f69d0ffae1fd2a96a80432f`, "add rust backend for
store login and macaroon handling instead of shelling out to snapcraft").

It is a native (FFI-ready) replacement for the responsibilities `surl`
previously covered for confdb-studio: Ubuntu One SSO login (with 2FA),
macaroon issuance/binding, and authenticated Snap Store requests.

## Status: wired in

`SnapStoreClient` (`lib/data/store/snap_store_client.dart`) now talks to the
Snap Store exclusively through this crate, bound from Dart over `dart:ffi`
in `lib/data/store/rust_auth_client.dart` (see `StoreAuthClient` for the
interface). `tool/store_helper.py` and the surl Python venv are gone.
Build the crate with `scripts/build_rust_backend.sh` before `flutter run`
or packaging — it stages `libsnapstore_auth.so` where the FFI client (and
the snap) expect it.

## What's new here vs. the upstream crate

The upstream crate only exposes a handful of fixed, typed endpoints
(`whoami`, `account_info`, `register_key`, `store_snaps`). confdb-studio's
`store_helper.py request METHOD PATH [CONTENT_TYPE]` command is generic: it
is used against `/api/v2/confdb-schemas` and
`/api/v2/confdb-schemas/build-assertion` with varying methods and content
types (JSON bodies, and signed `application/x.ubuntu.assertion` bodies).

To cover that, this vendored copy adds:

* [`AuthRuntime::request`](src/auth_core.rs) — an arbitrary authenticated
  request (`method`, `path`, optional raw `body`, optional
  `content_type`). It returns the raw `{status, body}` pair
  ([`ApiResponse`]) instead of assuming a JSON 2xx response, so the caller
  parses success/error bodies itself — the same contract
  `store_helper.py request` has today. Only transport-level failures (no
  session, DNS/TLS/timeout) are `Err`.
* `auth_request` — the matching C-ABI/FFI entry point in `src/lib.rs`,
  returning JSON `{"status": <int>, "body": "<raw body>"}`.

See `generic_request_sends_method_path_body_and_content_type` in
`tests/integration.rs` for the expected behavior (GET/POST, custom content
type, non-2xx passthrough, and the no-session error case).

## Build & test

```sh
cd rust
cargo test --release
../scripts/build_rust_backend.sh   # stages linux/rust/libsnapstore_auth.so
```

## Next steps (not done here)

* Add a Dart FFI client (mirroring
  `lib/services/ffi/snapstore_auth_client.dart` upstream) and a
  `RustStoreService`-equivalent service.
* Swap `SnapStoreClient` to call the FFI service instead of shelling out to
  `tool/store_helper.py`, dropping the `surl`/Python runtime dependency.
