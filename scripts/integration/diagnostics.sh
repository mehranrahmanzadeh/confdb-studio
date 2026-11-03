#!/bin/bash
# What snapd was doing when the suite failed. Safe to attach to a CI run: it
# collects changes, tasks and the daemon log, but never confdb *values* — a
# view can hold secrets.
set -uo pipefail

OUT=${1:-${RUNNER_TEMP:-/tmp}/snapd-diagnostics}
mkdir -p "$OUT"

run() {
  local name=$1; shift
  printf '$ %s\n' "$*" > "$OUT/$name"
  "$@" >> "$OUT/$name" 2>&1 || echo "(exited $?)" >> "$OUT/$name"
}

run version.txt snap version
run changes.txt snap changes
run schemas.txt snap known confdb-schema
run connections.txt snap connections --all
run snaps.txt snap list
run features.txt snap get system experimental

# The last few failed changes, with their task logs.
{
  for id in $(snap changes 2>/dev/null | awk '$2 == "Error" {print $1}' | tail -5); do
    printf '\n===== change %s =====\n' "$id"
    snap change "$id" 2>&1
  done
} > "$OUT/failed-changes.txt" 2>&1

journalctl -u snapd --no-pager -n 500 > "$OUT/snapd.log" 2>&1

echo "Diagnostics in $OUT:"
ls -la "$OUT"
