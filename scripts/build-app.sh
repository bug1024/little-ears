#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
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
    [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"
rm -rf "build/Little Ears.app"
mv "$app" "build/Little Ears.app"
rmdir "$staging"
printf 'Built: %s/build/Little Ears.app\n' "$PWD"
