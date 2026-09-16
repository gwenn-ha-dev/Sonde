#!/bin/bash
# Runs the unit tests. Same toolchain as build.sh: swiftc, no SPM, no dependencies.
# Only the dependency-free sources are compiled in — the SwiftUI layer needs a running
# app, and App.swift's @main would collide with the test entry point.
set -euo pipefail
cd "$(dirname "$0")/.."

# Minimum macOS, pinned. Without -target, swiftc stamps the binary with the
# installed SDK's version: the same source produced macOS 27 here and 26.6 on
# CI, and the README's claim went stale with every Xcode update.
DEPLOY="$(uname -m)-apple-macos26.0"

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

echo "› Compiling tests…"
xcrun swiftc \
    -target "$DEPLOY" \
    -O \
    -swift-version 5 \
    -framework AVFoundation \
    -o "$OUT/tests" \
    Sources/Models.swift Sources/Support.swift Sources/Favorites.swift \
    Sources/Loudness.swift Tests/main.swift

"$OUT/tests"
