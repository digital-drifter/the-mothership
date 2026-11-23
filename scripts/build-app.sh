#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Mothership
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Mothership.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Mothership" "$APP/Contents/MacOS/Mothership"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.mothership.app</string>
    <key>CFBundleName</key><string>Mothership</string>
    <key>CFBundleExecutable</key><string>Mothership</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built $APP"
