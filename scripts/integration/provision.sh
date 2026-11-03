#!/bin/bash
# Prepares a *disposable* machine for the writable snapd integration suite and
# marks it as safe to mutate.
#
# Run this only on a GitHub-hosted runner or inside an LXD virtual machine.
# It enables experimental confdb and optionally installs a public signed schema
# and custodian fixture. It never replaces snapd or imports private keys.
#
# Usage: sudo scripts/integration/provision.sh --kind github|lxd-vm [--custodian]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MARKER=/etc/confdb-studio-integration
KIND=
CUSTODIAN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND=${2:-}; shift 2 ;;
    --custodian) CUSTODIAN=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$KIND" in
  github|lxd-vm) ;;
  *) echo "usage: $0 --kind github|lxd-vm [--custodian]" >&2; exit 2 ;;
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

if [ "$CUSTODIAN" = true ]; then
  assertion="$SCRIPT_DIR/fixtures/confdb-studio-integration.assert"
  if [ ! -f "$assertion" ]; then
    echo "Missing public fixture: $assertion. Generate it with sign-fixture.sh." >&2
    exit 1
  fi
  headers=$(sed '/^$/q' "$assertion")
  fixture_account=$(printf '%s\n' "$headers" | sed -n 's/^account-id: //p')
  if ! printf '%s\n' "$headers" | grep -Fxq 'type: confdb-schema' ||
     ! printf '%s\n' "$headers" | grep -Fxq 'name: confdb-studio-integration' ||
     [[ ! "$fixture_account" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Expected a confdb-studio-integration schema with a valid account-id as the first assertion." >&2
    exit 1
  fi
fi

# --------------------------------------------------------------------- snapd
say "Waiting for snapd"
snap wait system seed.loaded
systemctl is-active --quiet snapd.socket || systemctl start snapd.socket

say "Enabling experimental.confdb"
# The feature can be off on a fresh system. Fail here if snapd doesn't support it.
snap set system experimental.confdb=true || {
  echo "Could not enable experimental.confdb on $(snap version | awk '/^snapd/{print $2}')." >&2
  echo "Install a snapd version that supports experimental.confdb." >&2
  exit 1
}

say "snapd is:"
snap version

# ------------------------------------------------------------------ fixtures
if [ "$CUSTODIAN" = true ]; then
  say "Acknowledging the public confdb-schema and its signing chain"
  snap ack "$assertion"
  snap known confdb-schema "account-id=$fixture_account" name=confdb-studio-integration >/dev/null

  say "Installing the custodian fixture snap"
  workdir=$(mktemp -d /var/tmp/confdb-studio-custodian.XXXXXX)
  trap 'rm -rf -- "$workdir"' EXIT
  src="$SCRIPT_DIR/fixtures/confdb-studio-custodian"
  cp -a "$src" "$workdir/snap"
  sed "s/account: TEST_ACCOUNT_ID/account: $fixture_account/" "$src/meta/snap.yaml" > "$workdir/snap/meta/snap.yaml"
  chmod +x "$workdir/snap"/meta/hooks/*
  snap pack "$workdir/snap" --filename "$workdir/custodian.snap" >/dev/null
  snap install --dangerous "$workdir/custodian.snap"
  snap connect confdb-studio-custodian:wifi-admin

  say "Verifying the fixtures"
  snap connections confdb-studio-custodian
  fixture_view="$fixture_account/confdb-studio-integration/wifi-admin"
  snap set "$fixture_view" ssid=provisioning-check
  snap get "$fixture_view" ssid
  snap set "$fixture_view" ssid!
fi

# -------------------------------------------------------------------- marker
say "Marking this machine as disposable"
cat > "$MARKER" <<EOF
# Written by scripts/integration/provision.sh. Its presence tells the
# confdb_studio integration suite that this machine may be mutated freely.
kind=$KIND
custodian=$CUSTODIAN
provisioned=$(date -Is)
EOF
chown root:root "$MARKER"
chmod 0644 "$MARKER"

say "Ready. Run the suite with:"
echo "  flutter test test/integration --dart-define=SNAPD_IT=true$([ "$CUSTODIAN" = true ] && echo ' --dart-define=SNAPD_IT_CUSTODIAN=true')"
