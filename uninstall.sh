#!/bin/bash
set -e
LABEL="com.ilya.stkhmonitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/StkhMonitor.app"

echo "StkhMonitor удалён (приложение и LaunchAgent)."
