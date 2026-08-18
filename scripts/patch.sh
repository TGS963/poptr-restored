#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <iphone|playcover> [--diagnostics] <input.ipa> <output.ipa>" >&2
    exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
readonly target="$1"
shift

diagnostics=false
if [[ "${1:-}" == "--diagnostics" ]]; then
    diagnostics=true
    shift
fi

[[ $# -eq 2 ]] || usage
readonly input="$1"
readonly output="$2"
readonly injector="${INSERT_DYLIB:-}"
readonly libraries="$ROOT/dist/$target"

[[ "$target" == "iphone" || "$target" == "playcover" ]] || usage
[[ -f "$input" ]] || { echo "Input IPA not found: $input" >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "Refusing to overwrite: $output" >&2; exit 1; }
[[ -x "$injector" ]] || {
    echo "Set INSERT_DYLIB to a compatible insert_dylib executable." >&2
    exit 1
}
[[ -f "$libraries/nilfix.dylib" ]] || {
    echo "Build the $target libraries first: scripts/build.sh $target" >&2
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
[[ -f "$game" ]] || { echo "App executable not found." >&2; exit 1; }
installed_libraries=()

inject_library() {
    local source="$1"
    local installed_name="$2"
    local load_path="@executable_path/$installed_name"

    if ! otool -L "$game" | grep -Fq "$load_path"; then
        "$injector" --inplace --all-yes --strip-codesig "$load_path" "$game"
    fi
    cp "$source" "$app/$installed_name"
    chmod +x "$app/$installed_name"
    installed_libraries+=("$app/$installed_name")
}

set_plist_boolean() {
    local key="$1"
    local value="$2"
    if plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
        plutil -replace "$key" -bool "$value" "$plist"
    else
        plutil -insert "$key" -bool "$value" "$plist"
    fi
}

inject_library "$libraries/nilfix.dylib" nilfix.dylib
inject_library "$libraries/accountfix.dylib" accountfix.dylib

case "$target" in
    iphone)
        if plutil -extract UISupportedDevices raw "$plist" >/dev/null 2>&1; then
            plutil -remove UISupportedDevices "$plist"
        fi
        if $diagnostics; then
            inject_library "$libraries/iosdebug.dylib" iosdebug.dylib
            set_plist_boolean UIFileSharingEnabled YES
            set_plist_boolean LSSupportsOpeningDocumentsInPlace YES
        fi
        ;;
    playcover)
        $diagnostics && usage
        inject_library "$libraries/gfxfix.dylib" gfxfix.dylib
        ;;
esac

rm -rf "$app/_CodeSignature"
rm -f "$app/embedded.mobileprovision"
for library in "${installed_libraries[@]}"; do
    codesign --force -s - "$library"
done
codesign --force --deep -s - "$app"

mkdir -p "$(dirname "$output")"
readonly output_parent="$(cd "$(dirname "$output")" && pwd)"
readonly output_path="$output_parent/$(basename "$output")"
(
    cd "$work"
    zip -qry "$output_path" Payload
)

echo "Created $output_path"
