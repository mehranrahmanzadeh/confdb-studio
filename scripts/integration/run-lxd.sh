#!/bin/bash
# Runs the snapd integration suite in a throwaway LXD virtual machine.
#
#   scripts/integration/run-lxd.sh            # stock snapd, built-in schema
#   scripts/integration/run-lxd.sh --custodian # + signed fixture and custodian
#
# A *virtual machine*, not a container: an LXD container shares the host's
# snapd, so the suite would be mutating your own machine's configuration.
#
# The VM is deleted at the end, including when a test fails, unless you pass
# --keep (useful for poking at a failure with `lxc shell <name>`).
set -euo pipefail

IMAGE=${IMAGE:-ubuntu:24.04}
NAME=${NAME:-confdb-it-$(date +%s)}
FLUTTER_CHANNEL=${FLUTTER_CHANNEL:-stable}
CUSTODIAN=false
KEEP=false

while [ $# -gt 0 ]; do
  case "$1" in
    --custodian) CUSTODIAN=true; shift ;;
    --keep) KEEP=true; shift ;;
    *) echo "usage: $0 [--custodian] [--keep]" >&2; exit 2 ;;
  esac
done

REPO=$(cd "$(dirname "$0")/../.." && pwd)
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

cleanup() {
  local status=$?
  if [ "$KEEP" = true ]; then
    echo "Keeping $NAME (delete it with: lxc delete --force $NAME)"
  else
    say "Deleting $NAME"
    lxc delete --force "$NAME" >/dev/null 2>&1 || true
  fi
  exit $status
}
trap cleanup EXIT

say "Launching $NAME ($IMAGE) as a VM"
lxc launch "$IMAGE" "$NAME" --vm -c limits.cpu=4 -c limits.memory=4GiB

# `lxc exec` only works once the guest agent is up, which is a little after the
# VM starts.
say "Waiting for the VM to come up"
for _ in $(seq 60); do
  lxc exec "$NAME" -- true >/dev/null 2>&1 && break
  sleep 5
done
lxc exec "$NAME" -- true || { echo "the VM never became reachable" >&2; exit 1; }
lxc exec "$NAME" -- cloud-init status --wait

say "Copying the working tree in"
# Only what the suite needs; no build output, no .git, no snaps.
tar czf - -C "$REPO" \
  --exclude=build --exclude=.git --exclude='*.snap' --exclude=linux/rust/target \
  lib test scripts pubspec.yaml pubspec.lock analysis_options.yaml assets \
  | lxc exec "$NAME" -- bash -c 'mkdir -p /root/confdb_studio && tar xzf - -C /root/confdb_studio'

say "Installing Flutter"
lxc exec "$NAME" -- snap install flutter --classic --channel="$FLUTTER_CHANNEL"
lxc exec "$NAME" -- bash -lc 'cd /root/confdb_studio && PATH=$PATH:/snap/bin flutter pub get'

say "Provisioning snapd"
provision_args=(--kind lxd-vm)
[ "$CUSTODIAN" = true ] && provision_args+=(--custodian)
# Match the relative invocation used by the GitHub workflow.
lxc exec "$NAME" --cwd /root/confdb_studio -- scripts/integration/provision.sh "${provision_args[@]}"

say "Running the suite"
defines=(--dart-define=SNAPD_IT=true)
target=test/integration/snapd_builtin_test.dart
if [ "$CUSTODIAN" = true ]; then
  defines+=(--dart-define=SNAPD_IT_CUSTODIAN=true)
  target=test/integration
fi

# Already root inside the VM, so no sudo and no polkit prompt.
if lxc exec "$NAME" -- bash -lc "cd /root/confdb_studio && PATH=\$PATH:/snap/bin flutter test $target ${defines[*]}"; then
  say "Passed"
else
  status=$?
  say "Failed — collecting diagnostics"
  lxc exec "$NAME" -- /root/confdb_studio/scripts/integration/diagnostics.sh /root/diagnostics || true
  rm -rf "$REPO/.integration-diagnostics"
  lxc file pull --recursive "$NAME/root/diagnostics" "$REPO/.integration-diagnostics" || true
  echo "Diagnostics copied to $REPO/.integration-diagnostics"
  exit $status
fi
