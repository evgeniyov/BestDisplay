#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh
app="$PWD/build/BestDisplay.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$PWD/build/BestDisplay-$version-macOS-arm64.dmg"
stage="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
mount="$stage/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mount" >/dev/null || return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT

mkdir -p "$stage/payload" "$mount"
ditto "$app" "$stage/payload/BestDisplay.app"
ln -s /Applications "$stage/payload/Applications"
hdiutil create -srcfolder "$stage/payload" -volname "BestDisplay $version" -format UDZO "$stage/image.dmg"
sign_identity="${BESTDISPLAY_SIGN_IDENTITY:--}"
if [[ "$sign_identity" != "-" ]]; then
    codesign --force --timestamp=none --sign "$sign_identity" "$stage/image.dmg"
    codesign --verify --strict "$stage/image.dmg"
fi
hdiutil verify "$stage/image.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$stage/image.dmg" >/dev/null
mounted=true
codesign --verify --strict "$mount/BestDisplay.app"
cmp "$app/Contents/MacOS/BestDisplay" "$mount/BestDisplay.app/Contents/MacOS/BestDisplay"
test "$(readlink "$mount/Applications")" = /Applications
hdiutil detach "$mount" >/dev/null
mounted=false
mv -f "$stage/image.dmg" "$dmg"
shasum -a 256 "$dmg"
