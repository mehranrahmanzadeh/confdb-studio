#!/bin/bash
# Host entry point: only the disposable VM is modified.
set -euo pipefail

usage() {
    echo "Usage: $0 [--keep] [--snapd-ref REF]"
    echo "Builds snapd's latest stable release unless --snapd-ref overrides it."
}

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
        echo "Retry, or pick one explicitly with --snapd-ref <tag-or-commit>." >&2
        return 1
    fi
    echo "$tag"
}

keep=false
snapd_ref=
while (($#)); do
    case "$1" in
        --keep) keep=true; shift ;;
        --snapd-ref) snapd_ref="${2:?Missing snapd ref}"; shift 2 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

command -v lxc >/dev/null
command -v curl >/dev/null
if [[ -z "$snapd_ref" ]]; then
    snapd_ref="$(latest_snapd_release)"
    echo "Latest stable snapd release: $snapd_ref"
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${SNAPD_IT_OUTPUT:-$root/build/snapd-integration}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
vm="local:confdb-it-$(date +%s)-$$"
archive="$(mktemp --suffix=.tar.gz)"
created=false
cleanup() {
    result=$?
    trap - EXIT
    if "$created"; then
        # `lxc exec` discards output when stdout is a plain file, so pipe it.
        lxc exec "$vm" -- journalctl -u snapd --no-pager 2>&1 |
            cat >"$output/snapd-journal.log" || true
        if lxc file pull "$vm/var/tmp/confdb-results/" "$output/" --recursive; then
            find "$output/confdb-results" -mindepth 1 -maxdepth 1 \
                -exec mv -ft "$output" {} + || true
            rmdir "$output/confdb-results" || true
        fi
        if "$keep"; then
            echo "VM retained: $vm (delete with: lxc delete --force $vm)"
        elif ! lxc delete --force "$vm"; then
            echo "Could not delete test VM: $vm" >&2
            result=1
        fi
    fi
    rm -f "$archive"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar -czf "$archive" -C "$root" \
    --exclude=.git --exclude=.dart_tool --exclude=build --exclude='*.snap' .
lxc launch ubuntu:24.04 "$vm" --vm \
    -c limits.cpu=4 -c limits.memory=8GiB -d root,size=35GiB
created=true
ready=false
for ((attempt=0; attempt<90; attempt++)); do
    if lxc exec "$vm" -- true 2>/dev/null; then
        ready=true
        break
    fi
    sleep 2
done
if ! "$ready"; then
    echo "VM agent did not become ready: $vm" >&2
    exit 1
fi
lxc exec "$vm" -- timeout 300 cloud-init status --wait
lxc exec "$vm" -- mkdir -p /opt/confdb-studio /var/tmp/confdb-results
lxc file push "$archive" "$vm/var/tmp/confdb-source.tar.gz"
lxc exec "$vm" -- tar -xzf /var/tmp/confdb-source.tar.gz -C /opt/confdb-studio
# The guest script refuses to run without this marker and a VM hypervisor.
lxc exec "$vm" -- touch /run/confdb-integration-vm
lxc exec "$vm" -- env SNAPD_REF="$snapd_ref" \
    FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.7}" \
    bash /opt/confdb-studio/scripts/integration/guest.sh
