#!/bin/bash
# Runs the unit tests. Same toolchain as build.sh: swiftc, no SPM, no dependencies.
# Only the dependency-free sources are compiled in — the SwiftUI layer needs a running
# app, and App.swift's @main would collide with the test entry point.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

echo "› Compiling tests…"
xcrun swiftc \
    -O \
    -swift-version 5 \
    -framework AVFoundation \
    -o "$OUT/tests" \
    Sources/Models.swift Sources/Support.swift Sources/Favorites.swift \
    Sources/Loudness.swift Tests/main.swift

"$OUT/tests"
