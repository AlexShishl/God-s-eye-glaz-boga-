#!/bin/bash
# Собирает «Глаз Бога.app» в папку build/.
# С флагом --install сразу кладёт его в «Программы» и перезапускает.
set -euo pipefail
cd "$(dirname "$0")"

# Подпись одним и тем же локальным сертификатом при каждой сборке.
# С подписью «-» (ad-hoc) macOS после каждой пересборки считает приложение новым
# и снова и снова просит «Запись экрана», хотя галочка уже стоит.
IDENTITY="Glaz Boga Local Signing"

find_identity() {
    security find-identity -p codesigning 2>/dev/null \
        | awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }' || true
}

create_identity() {
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/id.p12" -passout pass:glaz >/dev/null 2>&1 \
    && security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P glaz -T /usr/bin/codesign >/dev/null 2>&1
    local ok=$?
    rm -rf "$tmp"
    return $ok
}

sign_app() {
    local hash
    hash="$(find_identity)"
    if [ -z "$hash" ]; then
        echo "Создаю локальный сертификат «${IDENTITY}» для подписи (один раз)…"
        create_identity && hash="$(find_identity)"
    fi
    if [ -n "$hash" ] && codesign --force --deep --sign "$hash" "$1"; then
        return
    fi
    echo "⚠️  Не получилось подписать сертификатом, подписываю как раньше (ad-hoc)."
    codesign --force --deep --sign - "$1"
}

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchDrawer"

APP="build/Глаз Бога.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchDrawer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sign_app "$APP"

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
