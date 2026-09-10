#!/bin/bash
set -e
LABEL="com.ilya.stkhmonitor"
HELPER_LABEL="com.ilya.stkhmonitor.helper"
APP_NAME="StkhMonitor.app"
PLIST="/Library/LaunchAgents/$LABEL.plist"
USER_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HELPER_DAEMON="/Library/LaunchDaemons/$HELPER_LABEL.plist"

# Helper, поставленный пакетом, снимаем здесь. Helper, зарегистрированный из
# меню приложения (SMAppService), так не убрать — его надо снять кнопкой
# «Удалить helper» до удаления приложения.
if [ ! -f "$HELPER_DAEMON" ]; then
    echo "Если helper ставился из меню приложения, снимите его там до удаления:"
    echo "  Автоматизация → Удалить helper"
    echo
fi
sudo launchctl bootout "system/$HELPER_LABEL" >/dev/null 2>&1 || true
sudo rm -f "$HELPER_DAEMON"

# Выгружаем из всех графических сеансов: при быстром переключении пользователей
# приложение работает в каждом из них.
for uid in $(ps -axo uid=,comm= | awk '$2 ~ /\/loginwindow$/ && $1 >= 500 { print $1 }' | sort -u); do
    sudo launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
done
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

sudo rm -f "$PLIST"
rm -f "$USER_PLIST"
sudo rm -rf "/Applications/$APP_NAME"
rm -rf "$HOME/Applications/$APP_NAME"
sudo pkill -f "/$APP_NAME/Contents/MacOS/StkhMonitor" >/dev/null 2>&1 || true

echo "StkhMonitor удалён (приложение и LaunchAgent для всех пользователей)."
