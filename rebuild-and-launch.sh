#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Dewy.app"
TEMP_APP="/private/tmp/Dewy-rebuild-$$.app"
trap 'rm -rf "$TEMP_APP"' EXIT

cd "$ROOT"
swift build -c release
cp "$ROOT/.build/release/Dewy" "$APP/Contents/MacOS/Dewy"

# Mark each packaged build so it is easy to tell which version is running.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((VERSION + 1))" "$APP/Contents/Info.plist"

# The project lives in a synced folder. Sign a clean temporary copy, then put
# the signed bundle back without copying Finder metadata/resource forks.
ditto --noextattr --norsrc "$APP" "$TEMP_APP"
codesign --force --deep --sign - "$TEMP_APP"
codesign --verify --verbose=2 "$TEMP_APP"
ditto --noextattr --norsrc "$TEMP_APP" "$APP"
codesign --verify --verbose=2 "$APP"

# Replace all running copies so the opened app always matches the source.
killall -TERM Dewy >/dev/null 2>&1 || true
for _ in {1..12}; do
    if ! pgrep -x Dewy >/dev/null 2>&1; then break; fi
    sleep 0.25
done
open "$APP"
echo "Dewy rebuilt and relaunched: $APP"
