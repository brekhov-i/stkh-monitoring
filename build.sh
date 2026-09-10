#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/StkhMonitor.app"
HELPER_LABEL="com.ilya.stkhmonitor.helper"
APP_IDENTIFIER="com.ilya.stkhmonitor"
GENERATED_DIR="build/generated"
GENERATED_REQUIREMENT="$GENERATED_DIR/SigningRequirement.swift"

rm -rf "$APP" "$GENERATED_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$GENERATED_DIR"

# Универсальный бинарник: swiftc не умеет собирать несколько архитектур за один
# проход, поэтому собираем срезы по отдельности и склеиваем через lipo.
# Deployment target держим равным LSMinimumSystemVersion из Info.plist ниже —
# так компилятор сам поймает вызов API новее заявленного минимума.
ARCHS=(arm64 x86_64)
DEPLOYMENT_TARGET=11.0
SLICE_DIR="build/slices"

build_universal() {
    local output="$1"
    local name="$2"
    shift 2
    local slices=()
    rm -rf "$SLICE_DIR"
    mkdir -p "$SLICE_DIR"
    for ARCH in "${ARCHS[@]}"; do
        swiftc -O -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" "$@" -o "$SLICE_DIR/$name-$ARCH"
        slices+=("$SLICE_DIR/$name-$ARCH")
    done
    lipo -create -output "$output" "${slices[@]}"
    rm -rf "$SLICE_DIR"
}

SHARED_SOURCES=(Sources/Shared/DaemonControl.swift)

build_universal "$APP/Contents/MacOS/StkhMonitor" StkhMonitor \
    Sources/main.swift Sources/Schedule.swift Sources/AutomationWindow.swift "${SHARED_SOURCES[@]}"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>StkhMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_IDENTIFIER</string>
    <key>CFBundleExecutable</key>
    <string>StkhMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
</dict>
</plist>
EOF

CERT_NAME="${STKH_SIGNING_IDENTITY:-StkhMonitor Local Signing}"
if [ -z "$STKH_SIGNING_IDENTITY" ] && ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    ./make-cert.sh
fi

# Подписываем приложение первым: helper должен пускать к себе только его, а
# требование к подписи мы берём не из головы, а из фактически подписанного
# бандла. Поэтому порядок именно такой — подпись, затем требование, затем сборка
# helper'а, и в конце повторная подпись бандла уже вместе с helper'ом.
codesign --force --sign "$CERT_NAME" "$APP"

REQUIREMENT="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
if [ -z "$REQUIREMENT" ]; then
    echo "Не удалось получить designated requirement подписанного приложения." >&2
    exit 1
fi

ESCAPED_REQUIREMENT="$(printf '%s' "$REQUIREMENT" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
cat > "$GENERATED_REQUIREMENT" <<EOF
// Создаётся build.sh из фактической подписи приложения. Руками не править.
//
// Helper пускает к своему Mach-сервису только процессы, удовлетворяющие этому
// требованию. Оно меняется вместе с сертификатом подписи, поэтому после смены
// сертификата helper придётся переустановить.
let helperClientRequirement = "$ESCAPED_REQUIREMENT"
EOF

build_universal "$APP/Contents/MacOS/StkhHelper" StkhHelper \
    Sources/Helper/main.swift "${SHARED_SOURCES[@]}" "$GENERATED_REQUIREMENT"

# BundleProgram — путь относительно корня бандла: launchd запускает helper прямо
# из приложения, отдельной установки в /Library/PrivilegedHelperTools не нужно.
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_LABEL</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/StkhHelper</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_LABEL</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$APP_IDENTIFIER</string>
    </array>
</dict>
</plist>
EOF

codesign --force --sign "$CERT_NAME" --identifier "$HELPER_LABEL" "$APP/Contents/MacOS/StkhHelper"
# Повторная подпись бандла запечатывает добавленные helper и его плист.
codesign --force --sign "$CERT_NAME" "$APP"

echo "Собрано: $APP"
echo "Требование к клиенту helper'а: $REQUIREMENT"
