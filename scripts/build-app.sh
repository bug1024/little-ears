#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="debug"
with_aquarium=false
for argument in "$@"; do
    case "$argument" in
        debug|release) configuration="$argument" ;;
        --aquarium) with_aquarium=true ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 1 ;;
    esac
done
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p build
staging="$(mktemp -d build/.app-XXXXXX)"
app="$staging/Little Ears.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/LittleEars" "$app/Contents/MacOS/LittleEars"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for bundle in "$bin_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    case "$bundle" in *Tests.bundle) continue ;; esac
    cp -R "$bundle" "$app/Contents/Resources/"
done
if [ "$with_aquarium" = true ]; then
    python3 scripts/aquarium-assets/convert_tank.py --source local-assets/MarineAquarium3 --output "$app/Contents/Resources/AquariumAssets"
fi
codesign --force --sign - "$app"
rm -rf "build/Little Ears.app"
mv "$app" "build/Little Ears.app"
rmdir "$staging"
printf 'Built: %s/build/Little Ears.app\n' "$PWD"
