#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bash -n "$ROOT/scripts/build.sh"
bash -n "$ROOT/scripts/build-unlocks.sh"
bash -n "$ROOT/scripts/patch.sh"
bash -n "$ROOT/scripts/add-unlocks.sh"

if grep -Eq 'unlockmod|save_unlock' \
    "$ROOT/scripts/build.sh" "$ROOT/scripts/patch.sh"; then
    echo "Normal restoration scripts must not reference the unlock module." >&2
    exit 1
fi

"$ROOT/scripts/build-unlocks.sh" iphone "$work/iphone"
"$ROOT/scripts/build-unlocks.sh" playcover "$work/playcover"

clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation "$ROOT/tests/test_unlock.m" \
    -o "$work/test_unlock"
"$work/test_unlock"
"$ROOT/tests/test_packaging.sh"

echo "Unlock module checks passed."
