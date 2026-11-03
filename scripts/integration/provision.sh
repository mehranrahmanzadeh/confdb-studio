#!/bin/bash
# Prepares a *disposable* machine for the writable snapd integration suite and
# marks it as safe to mutate.
#
# Run this only on a GitHub-hosted runner or inside an LXD virtual machine. It
# enables an experimental snapd feature, and (with --test-keys) replaces snapd
# with a build that trusts test signing keys — neither belongs on a machine you
# care about.
#
# Usage: sudo scripts/integration/provision.sh --kind github|lxd-vm [--test-keys]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MARKER=/etc/confdb-studio-integration
KIND=
TEST_KEYS=false
# Pinned so the suite doesn't follow upstream's changing fixtures.
SNAPD_REF=${SNAPD_REF:-2.77}
SNAPD_REPO=${SNAPD_REPO:-https://github.com/canonical/snapd.git}
WORKDIR=${WORKDIR:-/var/tmp/confdb-it}

while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND=${2:-}; shift 2 ;;
    --test-keys) TEST_KEYS=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$KIND" in
  github|lxd-vm) ;;
  *) echo "usage: $0 --kind github|lxd-vm [--test-keys]" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- safety net
#
# The Dart suite re-checks all of this, but refusing here as well means a
# mistyped --kind can't even get as far as touching snapd.
say "Checking this machine is disposable"
case "$KIND" in
  github)
    [ "${GITHUB_ACTIONS:-}" = true ] || { echo "GITHUB_ACTIONS isn't set; this isn't an Actions runner." >&2; exit 1; }
    if [ -n "${RUNNER_ENVIRONMENT:-}" ] && [ "${RUNNER_ENVIRONMENT}" != github-hosted ]; then
      echo "This is a ${RUNNER_ENVIRONMENT} runner; only GitHub-hosted runners are disposable." >&2
      exit 1
    fi
    ;;
  lxd-vm)
    virt=$(systemd-detect-virt --vm || true)
    [ -n "$virt" ] && [ "$virt" != none ] || { echo "Not a VM (systemd-detect-virt --vm says '${virt:-unknown}')." >&2; exit 1; }
    if systemd-detect-virt --container >/dev/null 2>&1; then
      echo "This is a container, which shares the host's snapd. Use 'lxc launch --vm'." >&2
      exit 1
    fi
    ;;
esac

# --------------------------------------------------------------------- snapd
if [ "$TEST_KEYS" = true ]; then
  # Only a snapd built with -tags withtestkeys trusts the 'testrootorg' root
  # that upstream's confdb fixtures are signed with. There is no runtime way to
  # add a trusted key, so the whole suite that needs a signed schema needs this
  # build. It takes several minutes.
  say "Building snapd $SNAPD_REF with test keys (this takes several minutes)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git devscripts dpkg-dev build-essential fakeroot golang-go
  rm -rf "$WORKDIR/snapd"
  mkdir -p "$WORKDIR"
  git clone --depth 1 --branch "$SNAPD_REF" "$SNAPD_REPO" "$WORKDIR/snapd"
  cd "$WORKDIR/snapd"
  # snapd keeps its Debian packaging out of the way of the Go tree.
  rm -rf debian && cp -ar packaging/ubuntu-16.04 debian
  apt-get build-dep -y ./
  # A git checkout isn't vendored, but the package build expects it to be.
  if [ -x ./get-deps.sh ]; then ./get-deps.sh; else go mod vendor; fi
  ./mkversion.sh
  DEB_BUILD_OPTIONS='nocheck testkeys' dpkg-buildpackage -tc -b -Zgzip -uc -us
  cd "$WORKDIR"
  apt-get install -y --allow-downgrades ./snapd_*.deb ./snap-confine_*.deb
  cd /

  # Ubuntu's `snap` and snapd normally re-exec into the snapd *snap*, which is
  # the stock build and would not trust the test keys — the deb we just
  # installed would be bypassed entirely.
  say "Disabling snapd re-exec so the test-keys build is the one that runs"
  grep -q '^SNAP_REEXEC=' /etc/environment || echo 'SNAP_REEXEC=0' >> /etc/environment
  mkdir -p /etc/systemd/system/snapd.service.d
  cat > /etc/systemd/system/snapd.service.d/no-reexec.conf <<'EOF'
[Service]
Environment=SNAP_REEXEC=0
EOF
  systemctl daemon-reload
  systemctl restart snapd.service snapd.socket
fi

say "Waiting for snapd"
snap wait system seed.loaded
systemctl is-active --quiet snapd.socket || systemctl start snapd.socket

say "Enabling experimental.confdb"
# The feature is off by default on a fresh system. If this fails the snapd under
# test predates the flag (it was `experimental.registries` before 2.68, with no
# back-compat alias) and nothing below can work, so fail here rather than at a
# more confusing point later.
snap set system experimental.confdb=true || {
  echo "Could not enable experimental.confdb on $(snap version | awk '/^snapd/{print $2}')." >&2
  echo "The suite needs snapd 2.68 or later; set SNAPD_REF to a newer tag." >&2
  exit 1
}

say "snapd is:"
snap version

# ------------------------------------------------------------------ fixtures
if [ "$TEST_KEYS" = true ]; then
  say "Acknowledging the test confdb-schema"
  # Upstream's pre-signed fixture stream (account + account-key + confdb-schema),
  # taken from the same revision we built snapd from, so the signing key matches
  # the test keys compiled into it. We don't vendor it; we use it in place.
  snap ack "$WORKDIR/snapd/tests/lib/assertions/developer1-network.confdb"
  snap known confdb-schema account-id=developer1 name=network >/dev/null

  say "Installing the custodian fixture snap"
  # Ours, not upstream's: the suite needs a change-view hook whose rejection
  # behaviour it controls.
  src="$SCRIPT_DIR/fixtures/confdb-studio-custodian"
  chmod +x "$src"/meta/hooks/*
  snap pack "$src" --filename "$WORKDIR/confdb-studio-custodian.snap" >/dev/null
  snap install --dangerous "$WORKDIR/confdb-studio-custodian.snap"
  snap connect confdb-studio-custodian:wifi-admin

  say "Verifying the fixtures"
  snap connections confdb-studio-custodian
  snap set developer1/network/wifi-admin ssid=provisioning-check
  snap get developer1/network/wifi-admin ssid
  snap set developer1/network/wifi-admin ssid!
fi

# -------------------------------------------------------------------- marker
say "Marking this machine as disposable"
cat > "$MARKER" <<EOF
# Written by scripts/integration/provision.sh. Its presence tells the
# confdb_studio integration suite that this machine may be mutated freely.
kind=$KIND
test-keys=$TEST_KEYS
provisioned=$(date -Is)
EOF
chown root:root "$MARKER"
chmod 0644 "$MARKER"

say "Ready. Run the suite with:"
echo "  flutter test test/integration --dart-define=SNAPD_IT=true$([ "$TEST_KEYS" = true ] && echo ' --dart-define=SNAPD_IT_TEST_KEYS=true')"
