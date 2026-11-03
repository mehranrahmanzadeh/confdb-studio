#!/bin/bash
set -euo pipefail

if [[ $EUID != 0 || ! -f /run/confdb-integration-vm ]] ||
    ! systemd-detect-virt --vm --quiet; then
    echo "Refusing to replace snapd outside a marked disposable test VM." >&2
    exit 1
fi

exec > >(tee /var/tmp/confdb-results/guest.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends \
    git ca-certificates curl xz-utils unzip zip clang cmake ninja-build \
    pkg-config libgtk-3-dev liblzma-dev gnupg golang-go devscripts equivs

git init /opt/snapd
cd /opt/snapd
git remote add origin https://github.com/canonical/snapd.git
git fetch --depth 1 origin "${SNAPD_REF:?}"
git checkout --detach FETCH_HEAD
git rev-parse HEAD | tee /var/tmp/confdb-results/snapd-revision.txt
ln -s packaging/ubuntu-16.04 debian
mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control
./get-deps.sh
./mkversion.sh --ensure
DEB_BUILD_OPTIONS="nocheck testkeys parallel=4" dpkg-buildpackage -b -uc -us -Zgzip
apt-get install -y /opt/snapd_*.deb
mkdir -p /etc/systemd/system/snapd.service.d
printf '[Service]\nEnvironment=SNAP_REEXEC=0\n' >/etc/systemd/system/snapd.service.d/integration.conf
systemctl daemon-reload
systemctl restart snapd.socket snapd.service
export SNAP_REEXEC=0
timeout 180 snap wait system seed.loaded
# Keep the source-built daemon in charge, not a Store-provided snapd snap.
snap install core24
snap refresh --hold=forever
snap set system experimental.confdb=true

git clone --depth 1 --branch "${FLUTTER_VERSION:?}" \
    https://github.com/flutter/flutter.git /opt/flutter
export PATH="/opt/flutter/bin:$PATH"
export HOME=/root
export SNAP_GNUPG_HOME=/var/tmp/confdb-keyring
export SNAP_GNUPG_CMD=/opt/confdb-studio/scripts/integration/gpg
export CONFDB_ACCOUNT=developer1
export CONFDB_IT_ROOT=/var/tmp/confdb-fixtures
mkdir -m 700 "$SNAP_GNUPG_HOME"
mkdir -p "$CONFDB_IT_ROOT/remote"

cd /opt/confdb-studio
chmod +x scripts/integration/{gpg,snap,unprivileged-snap}
# Non-interactive, unprotected keys are confined to this disposable VM.
"$SNAP_GNUPG_CMD" --homedir "$SNAP_GNUPG_HOME" --batch --gen-key <<'EOF'
Key-Type: RSA
Key-Length: 4096
Name-Real: integration
Creation-Date: seconds=1451606400
Preferences: SHA512
EOF
snap export-key --account=developer1 integration >"$CONFDB_IT_ROOT/key-request"
cd /opt/snapd
go run /opt/confdb-studio/scripts/integration/trust.go \
    "$CONFDB_IT_ROOT/key-request" "$CONFDB_IT_ROOT/remote"
snap ack "$CONFDB_IT_ROOT/remote/account"
snap ack "$CONFDB_IT_ROOT/remote/account-key"
cd /opt/confdb-studio
snap sign -k integration <test/integration/fixtures/schema.json >"$CONFDB_IT_ROOT/schema.assert"
snap ack "$CONFDB_IT_ROOT/schema.assert"
cp "$CONFDB_IT_ROOT/schema.assert" "$CONFDB_IT_ROOT/remote/confdb-schema"
chmod +x test/integration/fixtures/custodian/meta/hooks/*
chmod +x test/integration/fixtures/custodian/bin/shell
snap pack test/integration/fixtures/custodian --filename=/var/tmp/studio-custodian.snap
snap install --dangerous /var/tmp/studio-custodian.snap
snap connect studio-custodian:admin
snap connect studio-custodian:observer
snap connect studio-custodian:reader
daemon_pid="$(systemctl show -p MainPID --value snapd)"
test "$(readlink "/proc/$daemon_pid/exe")" = /usr/lib/snapd/snapd
snap version > /var/tmp/confdb-results/snap-version.txt

flutter --version
flutter pub get
# A separate file contains the events; the console retains readable failures.
set +e
flutter test test/integration --concurrency=1 --dart-define=SNAPD_IT=true \
    --reporter=expanded --file-reporter=json:/var/tmp/confdb-results/tests.json
result=$?
set -e
snap changes > /var/tmp/confdb-results/changes.txt
exit "$result"
