#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
readonly fake_tools="$ROOT/tests/fake"

create_fixture() {
    local name="$1"
    shift
    local root="$work/$name"
    local app="$root/Payload/Test.app"
    mkdir -p "$app"
    plutil -create xml1 "$app/Info.plist"
    plutil -insert CFBundleExecutable -string Game "$app/Info.plist"
    touch "$app/Game"
    for library in "$@"; do
        touch "$app/$library"
        touch "$app/$library.load-command"
    done
    (
        cd "$root"
        zip -qry "$work/$name.ipa" Payload
    )
}

expect_failure() {
    local target="$1"
    local input="$2"
    local output="$3"
    if PATH="$fake_tools:$PATH" INSERT_DYLIB="$fake_tools/insert_dylib" \
        "$ROOT/scripts/add-unlocks.sh" "$target" "$input" "$output"; then
        echo "Expected add-unlocks.sh to reject $input" >&2
        exit 1
    fi
    [[ ! -e "$output" ]]
}

"$ROOT/scripts/build-unlocks.sh" iphone
"$ROOT/scripts/build-unlocks.sh" playcover

create_fixture raw
expect_failure iphone "$work/raw.ipa" "$work/raw-output.ipa"

create_fixture iphone nilfix.dylib accountfix.dylib
PATH="$fake_tools:$PATH" INSERT_DYLIB="$fake_tools/insert_dylib" \
    "$ROOT/scripts/add-unlocks.sh" \
    iphone "$work/iphone.ipa" "$work/iphone-output.ipa"
unzip -Z1 "$work/iphone-output.ipa" |
    grep -Fq 'Payload/Test.app/unlockmod.dylib'

create_fixture playcover nilfix.dylib accountfix.dylib gfxfix.dylib
PATH="$fake_tools:$PATH" INSERT_DYLIB="$fake_tools/insert_dylib" \
    "$ROOT/scripts/add-unlocks.sh" \
    playcover "$work/playcover.ipa" "$work/playcover-output.ipa"
unzip -Z1 "$work/playcover-output.ipa" |
    grep -Fq 'Payload/Test.app/unlockmod.dylib'

expect_failure iphone "$work/playcover.ipa" "$work/wrong-target.ipa"

create_fixture experimental nilfix.dylib accountfix.dylib inputfix.dylib
expect_failure iphone "$work/experimental.ipa" "$work/experimental-output.ipa"

create_fixture already-modded nilfix.dylib accountfix.dylib unlockmod.dylib
expect_failure iphone "$work/already-modded.ipa" "$work/double-output.ipa"

create_fixture missing-file nilfix.dylib accountfix.dylib
rm "$work/missing-file/Payload/Test.app/accountfix.dylib"
(
    cd "$work/missing-file"
    zip -qry -FS "$work/missing-file.ipa" Payload
)
expect_failure iphone "$work/missing-file.ipa" "$work/missing-output.ipa"

touch "$work/refuse-overwrite.ipa"
if PATH="$fake_tools:$PATH" INSERT_DYLIB="$fake_tools/insert_dylib" \
    "$ROOT/scripts/add-unlocks.sh" \
    iphone "$work/iphone.ipa" "$work/refuse-overwrite.ipa"; then
    echo "Expected add-unlocks.sh to refuse an existing output." >&2
    exit 1
fi
[[ -e "$work/refuse-overwrite.ipa" ]]

echo "Unlock packaging checks passed."
