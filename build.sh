#!/bin/bash
set -e
cd "$(dirname "$0")"

# 1. Бинарник — для CLI-режимов (--check, --line, разовая перебивка).
swiftc -O main.swift auto.swift phrase.swift menu.swift settings.swift log.swift autostart.swift learn.swift \
    -o switcher

# 2. Тот же код в .app-обёртке. Без неё macOS не показывает иконку в строке меню:
#    у процесса без Info.plist нет bundle identifier, и система его как приложение не регистрирует.
#    Кладём в build.noindex/: Spotlight пропускает каталоги на .noindex, поэтому вторая копия
#    приложения не всплывает в поиске рядом с установленной в /Applications.
mkdir -p build.noindex
APP="build.noindex/Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp switcher "$APP/Contents/MacOS/Switcher"
# Иконку рисует make-icon.swift — отдельно, чтобы не гонять её на каждой сборке.
[ -f Switcher.icns ] && cp Switcher.icns "$APP/Contents/Resources/Switcher.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Switcher</string>
    <key>CFBundleIconFile</key><string>Switcher</string>
    <key>CFBundleIdentifier</key><string>local.switcher</string>
    <key>CFBundleName</key><string>Switcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Только строка меню: ни иконки в доке, ни окна. -->
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Подпись постоянным самоподписанным сертификатом.
#
# Это не формальность: ad-hoc подпись даёт требование вида «хэш файла равен такому-то»,
# поэтому каждая пересборка выглядит для macOS новой программой и обнуляет выданный
# Универсальный доступ. С сертификатом требование звучит как «идентификатор local.switcher
# и leaf-сертификат такой-то» — хэш меняется, права остаются.
IDENTITY="Switcher Self Signed"
xattr -cr "$APP"        # иначе codesign споткнётся о расширенные атрибуты
# Стоит открыть папку сборки в Finder — и внутри бандла заводится .DS_Store. Для codesign
# это «detritus not allowed»: подпись сертификатом падает, а вместе с ней молча уезжают права.
find "$APP" -name .DS_Store -delete

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # Ошибку codesign показываем: спрятав её, мы получаем ad-hoc подпись и сброшенный
    # Универсальный доступ — без единого намёка на причину.
    codesign --force --sign "$IDENTITY" "$APP" \
        || echo "предупреждение: подписать сертификатом не удалось (см. ошибку выше)"
else
    echo "предупреждение: сертификата «$IDENTITY» нет в связке ключей, подписываю ad-hoc"
    echo "               (права Универсального доступа будут слетать при каждой сборке)"
    codesign --force --sign - "$APP" >/dev/null 2>&1
fi

# Установленную копию трогаем ТОЛЬКО по явной просьбе: ad-hoc подпись меняется на каждой
# сборке, macOS видит новую программу и сбрасывает выданный ей доступ. Пересобирать
# по десять раз и каждый раз заново выдавать права — невыносимо, поэтому ./build.sh --install.
if [ "$1" = "--install" ]; then
    rm -rf /Applications/Switcher.app
    cp -R "$APP" /Applications/
    xattr -cr /Applications/Switcher.app
    if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
        codesign --force --sign "$IDENTITY" /Applications/Switcher.app >/dev/null 2>&1 || true
    else
        codesign --force --sign - /Applications/Switcher.app >/dev/null 2>&1 || true
    fi
    echo "  обновлено: /Applications/Switcher.app"
fi

echo "собрано:"
echo "  CLI: $(pwd)/switcher"
echo "  App: $(pwd)/$APP   (запуск: open \"$(pwd)/$APP\")"
