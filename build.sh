#!/bin/bash
# Собирает «Глаз Бога.app» в папку build/.
# С флагом --install сразу кладёт его в «Программы» и перезапускает.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchDrawer"

APP="build/Глаз Бога.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchDrawer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/Глаз Бога.app"
    pkill -x NotchDrawer || true
    sleep 0.5
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Установлено и запущено: $DEST"
else
    echo ""
    echo "Готово: $APP"
    echo "Перетащи его в «Программы» и запусти. Открываю папку…"
    open build
fi
