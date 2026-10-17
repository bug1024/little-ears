#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Pass --aquarium to include the locally available aquarium scene assets.
bash scripts/build-app.sh release "$@"
app_path="build/Little Ears.app"
codesign --verify --deep --strict "$app_path"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
package_arch=$(uname -m)
dmg_path="build/Little-Ears-${app_version}-${package_arch}.dmg"
dmg_staging=$(mktemp -d build/.dmg-XXXXXX)
trap 'rm -rf "$dmg_staging"' EXIT

ditto "$app_path" "$dmg_staging/Little Ears.app"
ln -s /Applications "$dmg_staging/Applications"
cat > "$dmg_staging/安装说明.txt" <<'INSTALL'
Little Ears

将 Little Ears.app 拖到 Applications 文件夹，然后从「应用程序」打开。
首次使用时，在音乐库中添加自己的音频目录；安装包不包含音乐或个人资料库。

此版本要求 macOS 14 或更新版本，适用于与安装包文件名架构对应的 Mac。
本地测试包仅作临时签名，未经过 Apple 公证。首次打开如遇开发者验证提示，
确认文件来源后，可在「系统设置 → 隐私与安全性」中按系统提示处理。
INSTALL

hdiutil create -volname "Little Ears" -srcfolder "$dmg_staging" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg_path"
hdiutil verify "$dmg_path"
(
    cd build
    shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256"
)
printf 'Built: %s/%s\n' "$PWD" "$dmg_path"
