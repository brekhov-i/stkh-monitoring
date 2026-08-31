#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/StkhMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/StkhMonitor"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>StkhMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.ilya.stkhmonitor</string>
    <key>CFBundleExecutable</key>
    <string>StkhMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
</dict>
</plist>
EOF

CERT_NAME="StkhMonitor Local Signing"
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    "$(dirname "$0")/make-cert.sh"
fi
codesign --force --deep --sign "$CERT_NAME" "$APP"

echo "Собрано: $APP"
