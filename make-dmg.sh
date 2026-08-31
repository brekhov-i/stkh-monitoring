#!/bin/bash
set -e
cd "$(dirname "$0")"

./build.sh

APP="build/StkhMonitor.app"
VOL_NAME="StkhMonitor"
DMG_PATH="build/StkhMonitor.dmg"
STAGING="build/dmg-staging"

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING"

echo "Готово: $DMG_PATH"
