#!/bin/bash
# Signs the public integration fixture using an existing, Store-registered key.
# Run without sudo, using the same keyring as `snap keys`:
#
#   TEST_ACCOUNT_ID=... TEST_KEY_SHA3=... bash scripts/integration/sign-fixture.sh
#
# Only public assertions are written. The private key stays in the local keyring.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/fixtures/confdb-studio-integration.assert"}

if [ "$#" -gt 1 ] || [ -z "${TEST_ACCOUNT_ID:-}" ] || [ -z "${TEST_KEY_SHA3:-}" ]; then
  echo "usage: TEST_ACCOUNT_ID=... TEST_KEY_SHA3=... bash $0 [output.assert]" >&2
  exit 2
fi

for command in snap jq; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

key_name=$(snap keys --json | jq -er --arg sha "$TEST_KEY_SHA3" '
  [.[] | select(.["sha3-384"] == $sha) | .name]
  | if length == 1 then .[0]
    else error("Expected exactly one local snap key matching TEST_KEY_SHA3")
    end
')

registered_key=$(snap known --remote account-key "public-key-sha3-384=$TEST_KEY_SHA3")
owner=$(printf '%s\n' "$registered_key" | sed -n 's/^account-id: //p')
if [ "$owner" != "$TEST_ACCOUNT_ID" ]; then
  echo "The registered key belongs to account '$owner', not TEST_ACCOUNT_ID." >&2
  exit 1
fi

temporary=$(mktemp "$OUTPUT.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT

jq --arg account "$TEST_ACCOUNT_ID" --arg timestamp "$(date -u +%FT%TZ)" '
  . + {"authority-id": $account, "account-id": $account, "timestamp": $timestamp}
  | .body |= tojson
' "$SCRIPT_DIR/fixtures/confdb-studio-integration.json" \
  | snap sign --chain -k "$key_name" > "$temporary"

for type in confdb-schema account account-key; do
  if ! grep -Fxq "type: $type" "$temporary"; then
    echo "The signing output is missing the $type assertion." >&2
    exit 1
  fi
done

chmod 0644 "$temporary"
mv "$temporary" "$OUTPUT"
echo "Wrote public assertion chain to $OUTPUT"
echo "Review and commit this file; do not export or commit the private key."
