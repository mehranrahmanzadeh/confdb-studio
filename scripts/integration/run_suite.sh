#!/bin/bash
# Builds snapd from source with test keys and runs the integration suite on
# *this* machine, replacing its snapd. Both entry points use this script:
# the GitHub workflow runs it directly on an ephemeral hosted runner, and
# scripts/test_snapd_integration.sh runs it inside a disposable LXD VM.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
results=/var/tmp/confdb-results

if [[ $EUID != 0 ]]; then
    echo "Must run as root: this replaces the machine's snapd." >&2
    exit 1
fi
if [[ -f /run/confdb-integration-vm ]] && systemd-detect-virt --vm --quiet; then
    : # Disposable VM prepared by scripts/test_snapd_integration.sh.
elif [[ ${CONFDB_IT_DESTRUCTIVE:-} == 1 ]]; then
    # Ephemeral CI runner: the whole machine is discarded after the job. The
    # marker is what the Dart suite checks before it touches snapd.
    touch /run/confdb-integration-vm
else
    echo "Refusing to replace snapd on an unmarked machine." >&2
    echo "Run scripts/test_snapd_integration.sh for a disposable LXD VM, or" >&2
    echo "set CONFDB_IT_DESTRUCTIVE=1 only on a throwaway machine." >&2
    exit 1
fi

# snapd's latest stable release, as the releases API reports it. Its tag list
# is not version-ordered (recent tags include 'ppa' and '3.9.9-0sdhd5') and it
# has no 'main' branch, so neither tag order nor a branch name is usable here.
latest_snapd_release() {
    local auth=() tag
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    tag="$(curl -fsS --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' "${auth[@]}" \
        https://api.github.com/repos/canonical/snapd/releases/latest |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true
    # Guards against a rate-limited or changed response silently selecting junk.
    if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Could not resolve snapd's latest release (got '${tag:-<nothing>}')." >&2
        echo "Retry, or pick one explicitly with SNAPD_REF=<tag-or-commit>." >&2
        return 1
    fi
    echo "$tag"
}

mkdir -p "$results"
exec > >(tee "$results/run.log") 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends \
    git ca-certificates curl xz-utils unzip zip clang cmake ninja-build \
    pkg-config libgtk-3-dev liblzma-dev gnupg golang-go devscripts equivs

if [[ -z "${SNAPD_REF:-}" ]]; then
    SNAPD_REF="$(latest_snapd_release)"
    echo "Latest stable snapd release: $SNAPD_REF"
fi

git init /opt/snapd
cd /opt/snapd
git remote add origin https://github.com/canonical/snapd.git 2>/dev/null ||
    git remote set-url origin https://github.com/canonical/snapd.git
git fetch --depth 1 origin "$SNAPD_REF"
git checkout --detach FETCH_HEAD
git rev-parse HEAD | tee "$results"/snapd-revision.txt
echo "$SNAPD_REF" >"$results"/snapd-ref.txt
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

if [[ ! -d /opt/flutter ]]; then
    git clone --depth 1 --branch "${FLUTTER_VERSION:-3.47.7}" \
        https://github.com/flutter/flutter.git /opt/flutter
fi
export PATH="/opt/flutter/bin:$PATH"
export HOME=/root
export SNAP_GNUPG_HOME=/var/tmp/confdb-keyring
export SNAP_GNUPG_CMD="$root"/scripts/integration/gpg
export CONFDB_ACCOUNT=developer1
export CONFDB_IT_ROOT=/var/tmp/confdb-fixtures
mkdir -p -m 700 "$SNAP_GNUPG_HOME"
mkdir -p "$CONFDB_IT_ROOT/remote"

cd "$root"
chmod +x scripts/integration/{gpg,snap,unprivileged-snap}
# Non-interactive, unprotected keys never leave this disposable machine.
"$SNAP_GNUPG_CMD" --homedir "$SNAP_GNUPG_HOME" --batch --gen-key <<'EOF'
Key-Type: RSA
Key-Length: 4096
Name-Real: integration
Creation-Date: seconds=1451606400
Preferences: SHA512
EOF
snap export-key --account=developer1 integration >"$CONFDB_IT_ROOT/key-request"
cd /opt/snapd
go run "$root"/scripts/integration/trust.go \
    "$CONFDB_IT_ROOT/key-request" "$CONFDB_IT_ROOT/remote"
snap ack "$CONFDB_IT_ROOT/remote/account"
snap ack "$CONFDB_IT_ROOT/remote/account-key"
cd "$root"
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
snap version > "$results"/snap-version.txt

flutter --version
flutter pub get
# A separate file contains the events; the console retains readable failures.
set +e
flutter test test/integration --concurrency=1 --dart-define=SNAPD_IT=true \
    --reporter=expanded --file-reporter=json:"$results"/tests.json
result=$?
set -e
snap changes > "$results"/changes.txt
exit "$result"
