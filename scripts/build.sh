#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <iphone|playcover> [output-directory]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
readonly target="$1"
readonly output="${2:-$ROOT/dist/$target}"
mkdir -p "$output"

common_flags=(
    -dynamiclib
    -fblocks
    -fobjc-arc
    -arch arm64
    -Wall
    -Wextra
    -Werror
)

build_library() {
    local source="$1"
    local destination="$2"
    shift 2
    "${compiler[@]}" "${common_flags[@]}" "${platform_flags[@]}" \
        "$source" "$@" -o "$destination"
}

case "$target" in
    iphone)
        compiler=(xcrun --sdk iphoneos clang)
        sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
        platform_flags=(-isysroot "$sdk" -miphoneos-version-min=10.0)
        build_library "$ROOT/src/nil_string_fix.m" \
            "$output/nilfix.dylib" -framework Foundation
        build_library "$ROOT/src/apple_services_fix.m" \
            "$output/accountfix.dylib" -framework Foundation
        build_library "$ROOT/src/ios_diagnostics.m" \
            "$output/iosdebug.dylib" -framework Foundation
        ;;
    playcover)
        compiler=(clang)
        platform_flags=(-mmacosx-version-min=11.0)
        build_library "$ROOT/src/nil_string_fix.m" \
            "$output/nilfix.dylib" -framework Foundation
        build_library "$ROOT/src/apple_services_fix.m" \
            "$output/accountfix.dylib" -framework Foundation
        build_library "$ROOT/src/retained_backing_fix.m" \
            "$output/gfxfix.dylib" -framework Foundation -framework QuartzCore
        ;;
    *)
        usage
        ;;
esac

shasum -a 256 "$output"/*.dylib
