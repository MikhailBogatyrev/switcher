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

# Подписываем не на месте, а в копии вне iCloud.
#
# Папка проекта лежит на Рабочем столе, а он синхронизируется: iCloud вешает на бандл
# com.apple.FinderInfo и com.apple.fileprovider.fpfs#P и возвращает их сразу после
# xattr -cr. Для codesign это «resource fork, Finder information, or similar detritus
# not allowed» — подпись сертификатом падает, остаётся ad-hoc, и Универсальный доступ
# слетает на ровном месте. Во временном каталоге атрибутов взяться неоткуда.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Switcher.app"
xattr -cr "$STAGE/Switcher.app"
# Стоит открыть папку сборки в Finder — и внутри бандла заводится .DS_Store. Для codesign
# это тот же «detritus not allowed».
find "$STAGE/Switcher.app" -name .DS_Store -delete

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # Ошибку codesign показываем: спрятав её, мы получаем ad-hoc подпись и сброшенный
    # Универсальный доступ — без единого намёка на причину.
    codesign --force --sign "$IDENTITY" "$STAGE/Switcher.app" \
        || echo "предупреждение: подписать сертификатом не удалось (см. ошибку выше)"
else
    echo "предупреждение: сертификата «$IDENTITY» нет в связке ключей, подписываю ad-hoc"
    echo "               (права Универсального доступа будут слетать при каждой сборке)"
    codesign --force --sign - "$STAGE/Switcher.app" >/dev/null 2>&1
fi

# Подписанный бандл возвращаем на место: сама подпись лежит внутри файлов, поэтому
# копирование обратно в iCloud её не портит — портит только повторный codesign там же.
rm -rf "$APP"
cp -R "$STAGE/Switcher.app" "$APP"

# Установленную копию трогаем ТОЛЬКО по явной просьбе: ad-hoc подпись меняется на каждой
# сборке, macOS видит новую программу и сбрасывает выданный ей доступ. Пересобирать
# по десять раз и каждый раз заново выдавать права — невыносимо, поэтому ./build.sh --install.
if [ "$1" = "--install" ]; then
    # Ставим уже подписанную копию из STAGE и заново не подписываем: повторная подпись
    # ничего не добавляет, а вот сорваться в ad-hoc может.
    osascript -e 'quit app "Switcher"' >/dev/null 2>&1 || true
    # Дожидаемся, пока процесс действительно уйдёт: если открыть приложение, пока LaunchServices
    # ещё держит прежний экземпляр, open отвечает «error -609» и не запускает ничего.
    for _ in $(seq 20); do
        pgrep -f "Switcher.app/Contents/MacOS/Switcher" >/dev/null || break
        sleep 0.25
    done
    rm -rf /Applications/Switcher.app
    cp -R "$STAGE/Switcher.app" /Applications/
    echo "  обновлено: /Applications/Switcher.app"
    sleep 1
    open -a /Applications/Switcher.app
fi

rm -rf "$STAGE"

echo "собрано:"
echo "  CLI: $(pwd)/switcher"
echo "  App: $(pwd)/$APP   (запуск: open \"$(pwd)/$APP\")"
