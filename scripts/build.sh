#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/build}"
APP_PATH="$OUTPUT_DIR/Reminder Calendars.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$PROJECT_DIR/build/module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP_PATH/Contents/MacOS/RemindersCalendarFilter"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign - --entitlements "$PROJECT_DIR/RemindersCalendarFilter.entitlements" "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
