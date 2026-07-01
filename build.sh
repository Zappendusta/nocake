#!/bin/bash
# Build NoCake.app (LSUIElement, no Dock/menu-bar icon) from main.swift.
set -euo pipefail
cd "$(dirname "$0")"

APP="NoCake.app"
BIN="$APP/Contents/MacOS/NoCake"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$BIN" \
    -framework AppKit -framework Carbon

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NoCake</string>
  <key>CFBundleExecutable</key><string>NoCake</string>
  <key>CFBundleIdentifier</key><string>com.pdettmer.nocake</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the Accessibility/Input-Monitoring grant sticks across launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run:   open $APP    (grant Accessibility + Input Monitoring when prompted)"
echo "Test:  $BIN --selftest"
