#!/bin/bash
set -e
cd "$(dirname "$0")"

./build.sh

APP_NAME="StkhMonitor.app"
SRC="build/$APP_NAME"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME"
LABEL="com.ilya.stkhmonitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$DEST_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/StkhMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Установлено: $DEST"
echo "Автозапуск при входе в систему настроен (LaunchAgent: $PLIST)"
echo "Приложение запущено — иконка должна появиться в строке меню."
