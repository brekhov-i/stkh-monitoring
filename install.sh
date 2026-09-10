#!/bin/bash
set -e
cd "$(dirname "$0")"

./build.sh

APP_NAME="StkhMonitor.app"
SRC="build/$APP_NAME"
DEST="/Applications/$APP_NAME"
LABEL="com.ilya.stkhmonitor"
PLIST="/Library/LaunchAgents/$LABEL.plist"
USER_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Ставим в /Applications и регистрируем LaunchAgent в /Library, а не в домашней
# папке. Домашний каталог одного пользователя другим недоступен, поэтому при
# быстром переключении пользователей иконка в строке меню появлялась только у
# того, кто ставил приложение. Системный агент launchd грузит в каждый
# графический сеанс — иконка есть у всех вошедших.
echo "Нужны права администратора: приложение ставится для всех пользователей."

# uid всех открытых графических сеансов: у каждого свой домен launchd gui/<uid>,
# и опознаются они по loginwindow — по одному процессу на сеанс.
session_uids() {
    ps -axo uid=,comm= | awk '$2 ~ /\/loginwindow$/ && $1 >= 500 { print $1 }' | sort -u
}

for uid in $(session_uids); do
    sudo launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
done
sudo pkill -f "^$DEST/Contents/MacOS/StkhMonitor$" >/dev/null 2>&1 || true

sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"

sudo tee "$PLIST" >/dev/null <<EOF
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
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

# Старый пер-юзерный агент и копия в ~/Applications только мешают: при входе
# приложение стартовало бы дважды, а второй экземпляр молча завершается.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$USER_PLIST"
rm -rf "$HOME/Applications/$APP_NAME"

for uid in $(session_uids); do
    sudo launchctl bootstrap "gui/$uid" "$PLIST" || true
done

echo "Установлено: $DEST"
echo "Автозапуск настроен для всех пользователей (LaunchAgent: $PLIST)"
echo "Иконка должна появиться в строке меню в каждом открытом сеансе."
echo
echo "Чтобы запуск и остановка stkh-client не спрашивали пароль (в том числе у"
echo "второго пользователя), включите в меню: Автоматизация → Установить helper…"
