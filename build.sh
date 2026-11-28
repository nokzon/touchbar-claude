#!/bin/sh
# Builds build/Touchbar Claude.app
set -e
cd "$(dirname "$0")"
APP="build/Touchbar Claude.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/TouchbarClaude" Sources/*.swift -framework Cocoa
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Touchbar Claude</string>
  <key>CFBundleDisplayName</key><string>Touchbar Claude</string>
  <key>CFBundleIdentifier</key><string>com.touchbarclaude.app</string>
  <key>CFBundleExecutable</key><string>TouchbarClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>To type /model and /effort into your Claude session when you pick them on the Touch Bar.</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
