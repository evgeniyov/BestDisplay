#!/bin/bash
# Compiles and runs the pure-logic tests (no display hardware needed).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/ModuleCache
out="$(mktemp -d "$PWD/.build/tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/ModuleCache" \
  Sources/CubeLUT.swift Sources/ProfileURL.swift Sources/HardwareOptions.swift \
  Sources/DisplaySettings.swift Sources/DisplayIdentity.swift Sources/DisplayIdentityMigration.swift \
  Sources/DisplayRestoreState.swift Sources/HDRTuningPattern.swift Sources/PanelSize.swift \
  Sources/Placement.swift Sources/HDMICEC.swift Tests/*.swift -o "$out/tests"
"$out/tests"
