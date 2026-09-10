#!/bin/bash
set -e
cd "$(dirname "$0")"

./build.sh

APP="build/StkhMonitor.app"
LABEL="com.ilya.stkhmonitor"
VOL_NAME="StkhMonitor"
PKG_ROOT="build/pkg-root"
PKG_SCRIPTS="build/pkg-scripts"
PKG="build/StkhMonitor.pkg"
DMG_PATH="build/StkhMonitor.dmg"
STAGING="build/dmg-staging"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS" "$PKG" "$DMG_PATH" "$STAGING"
mkdir -p "$PKG_ROOT" "$PKG_SCRIPTS" "$STAGING"

# Внутри DMG лежит не сам бандл, а пакет. Перетаскивание в «Программы» ставит
# приложение только текущему пользователю и ничего не знает ни про системный
# LaunchAgent, ни про helper — а именно они и нужны, чтобы иконка была у всех
# пользователей и остановка демона не спрашивала пароль.
cp -R "$APP" "$PKG_ROOT/"
cp installer/postinstall "$PKG_SCRIPTS/postinstall"
chmod +x "$PKG_SCRIPTS/postinstall"

pkgbuild \
    --root "$PKG_ROOT" \
    --install-location /Applications \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$LABEL.installer" \
    --version "$VERSION" \
    "$PKG"

# Подписываем, только если в окружении есть Installer-сертификат: самоподписанный
# Installer всё равно не считает доверенным, и подпись им ничего не даёт.
if [ -n "$STKH_INSTALLER_IDENTITY" ]; then
    productsign --sign "$STKH_INSTALLER_IDENTITY" "$PKG" "$PKG.signed"
    mv "$PKG.signed" "$PKG"
    echo "Пакет подписан: $STKH_INSTALLER_IDENTITY"
fi

cp "$PKG" "$STAGING/Установить StkhMonitor.pkg"

cat > "$STAGING/Прочтите меня.txt" <<TXT
StkhMonitor $VERSION

Установка: откройте «Установить StkhMonitor.pkg» и следуйте шагам.
Потребуется пароль администратора — установщик ставит приложение для всех
пользователей компьютера.

Пакет:
  • кладёт StkhMonitor.app в «Программы»;
  • включает автозапуск в каждом сеансе, поэтому иконка в строке меню есть у
    всех пользователей, а не только у того, кто ставил;
  • поднимает привилегированный helper, поэтому запуск и остановка stkh-client
    не спрашивают пароль — в том числе у второго пользователя;
  • запускает приложение сразу во всех уже открытых сеансах.

Если macOS откажется открывать пакет («не удалось проверить разработчика»),
нажмите на нём правой кнопкой → «Открыть» и подтвердите, либо разрешите запуск
в «Системных настройках» → «Конфиденциальность и безопасность».

Удаление: скрипт uninstall.sh из репозитория приложения.
TXT

hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING" "$PKG_ROOT" "$PKG_SCRIPTS"

echo "Готово: $DMG_PATH"
echo "Внутри: Установить StkhMonitor.pkg (версия $VERSION)"
