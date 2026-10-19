#!/usr/bin/env bash
# Builds the Rust auth backend (libsnapstore_auth) and stages it next to the
# Flutter app's Linux executable so the FFI client (lib/data/store/
# rust_auth_client.dart) finds it at runtime. Run this before `flutter run`
# or packaging — the app no longer uses tool/store_helper.py/surl.
#
# Usage:
#   ./scripts/build_rust_backend.sh [path/to/snapstore-auth]
#
# The default crate location is the vendored `rust/` directory at the repo
# root (pass a path to build a different checkout instead). The resulting
# shared library is copied to
#   linux/rust/libsnapstore_auth.so
# and into build/linux/x64/<config>/bundle/lib/libsnapstore_auth.so when
# that tree exists — the actual runtime location `flutter run` uses
# (linux/CMakeLists.txt sets $ORIGIN/lib as the executable's rpath; the
# binary runs from build/linux/x64/<config>/bundle/, not the dir above it).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="${1:-$APP_DIR/rust}"
export PATH="$HOME/.cargo/bin:$PATH"

echo ">> cargo build --release ($CRATE_DIR)"
cd "$CRATE_DIR"
cargo build --release

SO="target/release/libsnapstore_auth.so"
[ -f "$SO" ] || { echo "missing $SO" >&2; exit 1; }

# Stage for `flutter run` / packaged app.
mkdir -p "$APP_DIR/linux/rust"
cp -f "$SO" "$APP_DIR/linux/rust/libsnapstore_auth.so"
echo ">> staged: $APP_DIR/linux/rust/libsnapstore_auth.so"

for cfg in debug release; do
  dst="$APP_DIR/build/linux/x64/$cfg/bundle/lib"
  if [ -d "$APP_DIR/build/linux/x64/$cfg/bundle" ]; then
    mkdir -p "$dst"
    cp -f "$SO" "$dst/libsnapstore_auth.so"
    echo ">> staged: $dst/libsnapstore_auth.so"
  fi
done

echo ">> done. Run the app normally; for a manual build set:"
echo "   SNAPSTORE_AUTH_LIB=$PWD/linux/rust/libsnapstore_auth.so"
