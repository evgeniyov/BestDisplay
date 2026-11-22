#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/ModuleCache build
staging="$(mktemp -d "$PWD/.build/bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/BestDisplay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

sdk="$(xcrun --show-sdk-path)"
for source in Sources/*.m; do
  name="$(basename "$source" .m)"
  xcrun clang -fobjc-arc -target arm64-apple-macosx14.0 -isysroot "$sdk" \
    -c "$source" -o "$staging/$name.o"
done
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/ModuleCache" -import-objc-header Sources/VirtualDisplay.h \
  Sources/*.swift "$staging"/*.o -o "$app/Contents/MacOS/BestDisplay"

sign_identity="${BESTDISPLAY_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp=none --sign "$sign_identity" "$app"
fi
codesign --verify --strict "$app"
ditto "$app" build/BestDisplay.app
printf '%s\n' "$PWD/build/BestDisplay.app"
