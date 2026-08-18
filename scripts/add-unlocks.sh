#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <iphone|playcover> <restored-input.ipa> <output.ipa>" >&2
    exit 2
}

[[ $# -eq 3 ]] || usage
readonly target="$1"
readonly input="$2"
readonly output="$3"
readonly injector="${INSERT_DYLIB:-}"
readonly unlock_library="$ROOT/dist/unlocks/$target/unlockmod.dylib"

[[ "$target" == "iphone" || "$target" == "playcover" ]] || usage
[[ -f "$input" ]] || { echo "Input IPA not found: $input" >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "Refusing to overwrite: $output" >&2; exit 1; }
[[ -x "$injector" ]] || {
    echo "Set INSERT_DYLIB to a compatible insert_dylib executable." >&2
    exit 1
}
[[ -f "$unlock_library" ]] || {
    echo "Build the unlock module first: scripts/build-unlocks.sh $target" >&2
    exit 1
}

readonly work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$input" -d "$work"

shopt -s nullglob
apps=("$work/Payload/"*.app)
[[ ${#apps[@]} -eq 1 ]] || {
    echo "Expected exactly one app bundle in Payload." >&2
    exit 1
}
readonly app="${apps[0]}"
readonly plist="$app/Info.plist"
readonly executable="$(plutil -extract CFBundleExecutable raw "$plist")"
readonly game="$app/$executable"
readonly load_path="@executable_path/unlockmod.dylib"
[[ -f "$game" ]] || { echo "App executable not found." >&2; exit 1; }
readonly load_commands="$(otool -L "$game")"

require_library() {
    local installed_name="$1"
    local required_path="@executable_path/$installed_name"
    if [[ ! -f "$app/$installed_name" ]] ||
        [[ "$load_commands" != *"$required_path"* ]]; then
        echo "Input is not a clean restored $target IPA: missing $installed_name." >&2
        exit 1
    fi
}

require_library nilfix.dylib
require_library accountfix.dylib
if [[ "$target" == "playcover" ]]; then
    require_library gfxfix.dylib
elif [[ "$load_commands" == *"@executable_path/gfxfix.dylib"* ]]; then
    echo "Input is a PlayCover IPA, not an iPhone IPA." >&2
    exit 1
fi
if [[ "$load_commands" == *"$load_path"* ]]; then
    echo "Input already contains the optional unlock modification." >&2
    exit 1
fi

for library in "$app"/*.dylib; do
    name="$(basename "$library")"
    case "$target:$name" in
        iphone:nilfix.dylib|iphone:accountfix.dylib|\
        playcover:nilfix.dylib|playcover:accountfix.dylib|\
        playcover:gfxfix.dylib)
            ;;
        *)
            echo "Input is not a clean restored $target IPA: unexpected $name." >&2
            exit 1
            ;;
    esac
done

"$injector" --inplace --all-yes --strip-codesig "$load_path" "$game"
cp "$unlock_library" "$app/unlockmod.dylib"
chmod +x "$app/unlockmod.dylib"

rm -rf "$app/_CodeSignature"
rm -f "$app/embedded.mobileprovision"
codesign --force -s - "$app/unlockmod.dylib"
codesign --force --deep -s - "$app"

mkdir -p "$(dirname "$output")"
readonly output_parent="$(cd "$(dirname "$output")" && pwd)"
readonly output_path="$output_parent/$(basename "$output")"
(
    cd "$work"
    zip -qry "$output_path" Payload
)

echo "Created $output_path"
