#!/bin/bash
#
# Установка Switcher на новую машину.
#
#   ./install.sh
#
# Делает три вещи: заводит постоянный сертификат для подписи, собирает и кладёт
# программу в /Applications, запускает её. Дальше остаётся один ручной шаг —
# выдать Универсальный доступ, за пользователя это сделать нельзя.

set -e
cd "$(dirname "$0")"

IDENTITY="Switcher Self Signed"

# --- 1. Сертификат -----------------------------------------------------------
#
# Подпись сертификатом — не косметика. С ad-hoc подписью требование, по которому macOS
# опознаёт программу, звучит как «хэш файла равен такому-то»: каждая пересборка выглядит
# новой программой, и выданный Универсальный доступ обнуляется. С сертификатом требование
# привязано к нему, а не к файлу, и доступ выдаётся один раз навсегда.

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "✓ сертификат «$IDENTITY» уже в связке ключей"
else
    echo "· создаю постоянный сертификат «$IDENTITY»…"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    # Расширения задаём файлом, а не флагом -addext: системный LibreSSL его не везде знает.
    cat > "$TMP/cert.cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Switcher Self Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/sw.key" -out "$TMP/sw.crt" \
        -config "$TMP/cert.cfg" -extensions v3 >/dev/null 2>&1

    openssl pkcs12 -export -inkey "$TMP/sw.key" -in "$TMP/sw.crt" \
        -out "$TMP/sw.p12" -passout pass: >/dev/null 2>&1

    KEYCHAIN=$(security default-keychain -d user | tr -d ' "')
    # -T /usr/bin/codesign — чтобы подпись не спрашивала разрешение на ключ при каждой сборке.
    security import "$TMP/sw.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign >/dev/null
    echo "✓ сертификат создан (действует 10 лет)"
fi

# --- 2. Программа ------------------------------------------------------------

if command -v swiftc >/dev/null 2>&1; then
    echo "· собираю из исходников…"
    ./build.sh --install
else
    # Xcode Command Line Tools не стоят — ставим готовый бандл и подписываем его
    # уже здешним сертификатом: чужая подпись на новой машине не проверяется.
    if [ ! -d "Switcher.app" ]; then
        echo "✗ нет ни swiftc, ни готового Switcher.app."
        echo "  Поставьте инструменты разработчика: xcode-select --install"
        exit 1
    fi
    echo "· swiftc не найден — ставлю готовый бандл"
    rm -rf /Applications/Switcher.app
    cp -R Switcher.app /Applications/
    xattr -cr /Applications/Switcher.app          # снимаем карантин после переноса
    find /Applications/Switcher.app -name .DS_Store -delete
    codesign --force --sign "$IDENTITY" /Applications/Switcher.app
    echo "  обновлено: /Applications/Switcher.app"
fi

# --- 3. Известные дыры системного словаря ------------------------------------
#
# Русский словарь macOS в целом хорош, но «раскладка» в нём отсутствует во всех формах —
# и это ровно то слово, на котором в первую очередь спотыкаешься, объясняя проблему.
# Автомат чинит слово только если результат — настоящее слово другого языка, поэтому
# такие пробелы закрываются обучением. Уроки ложатся в ~/Library/Application Support/switcher.

if [ -x "./switcher" ]; then
    echo "· доучиваю слова, которых нет в словаре macOS…"
    ./switcher --teach hfcrkflrf hfcrkflre hfcrkflrb hfcrkflrt hfcrkflrjq hfcrkflrfvb >/dev/null
    echo "  раскладка / раскладку / раскладки / раскладке / раскладкой / раскладками"
fi

# --- 4. Запуск ---------------------------------------------------------------

pkill -f "Switcher.app/Contents/MacOS/Switcher" 2>/dev/null || true
sleep 1
open -a /Applications/Switcher.app

cat <<'DONE'

Готово. Остался один шаг, который может сделать только человек:

  Системные настройки → Конфиденциальность и безопасность → Универсальный доступ
  → включить Switcher

Без него программа видна в строке меню, но не может ни прочитать выделение,
ни впечатать исправление. Выдать доступ достаточно один раз: подпись сертификатом
переживает пересборки.

Автозапуск включается в меню самой программы: «Запускать при входе в систему».
DONE
