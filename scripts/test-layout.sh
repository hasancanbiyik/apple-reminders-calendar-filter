#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$PROJECT_DIR/build/module-cache" \
    "$PROJECT_DIR/Sources/Models.swift" \
    "$PROJECT_DIR/Sources/SyncController.swift" \
    "$PROJECT_DIR/Sources/ControlPanel.swift" \
    "$PROJECT_DIR/Tests/LayoutSmoke.swift" \
    -o "$PROJECT_DIR/build/layout-test"
"$PROJECT_DIR/build/layout-test" "$PROJECT_DIR/build/list-layout.png"
