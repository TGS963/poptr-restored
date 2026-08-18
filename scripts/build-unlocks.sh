#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <iphone|playcover> [output-directory]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
readonly target="$1"
readonly output="${2:-$ROOT/dist/unlocks/$target}"
mkdir -p "$output"

flags=(
    -dynamiclib
    -fblocks
    -fobjc-arc
    -arch arm64
    -Wall
    -Wextra
    -Werror
)

case "$target" in
    iphone)
        sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
        compiler=(xcrun --sdk iphoneos clang)
        platform_flags=(-isysroot "$sdk" -miphoneos-version-min=10.0)
        ;;
    playcover)
        compiler=(clang)
        platform_flags=(-mmacosx-version-min=11.0)
        ;;
    *)
        usage
        ;;
esac

"${compiler[@]}" "${flags[@]}" "${platform_flags[@]}" \
    "$ROOT/src/save_unlock.m" -framework Foundation \
    -o "$output/unlockmod.dylib"
shasum -a 256 "$output/unlockmod.dylib"
