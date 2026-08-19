import Cocoa
import Carbon

// MARK: - Автоматический режим
//
// Перехватываем набор, копим текущее слово и на разделителе решаем, не абракадабра ли это.
// Разделитель придерживаем: сначала правка, потом уже он — так в тексте не мелькает мусор.
// Критерий: слово не проходит проверку в языке своей раскладки, а после перебивки
// проходит в языке другой. Словари берём системные — те же, что подчёркивают в TextEdit.

private var autoLayouts: [Layout] = []
var buffer = ""
private var lastFix: (typed: String, fixed: String)?


/// Клавиши, после которых текущее слово теряет смысл: стрелки, Enter, Tab, Esc.
private let resetKeys: Set<Int64> = [123, 124, 125, 126, 36, 76, 48, 53, 115, 116, 119, 121]

/// Символ считается частью слова, если он буква хотя бы в одной из раскладок.
/// Это не педантизм: «.» на русской клавиатуре — это «ю», а «[» — «х». Обрывая слово
/// на них, мы бы не починили ни «свою», ни «люблю», ни «объём».
func isWordCharacter(_ character: Character, layouts: [Layout]) -> Bool {
    if character.isLetter { return true }
    for source in layouts {
        guard let key = source.charToKey[character] else { continue }
        for target in layouts where target.id != source.id {
            let twin = target.keyToChar[Layout.Key(code: key.code, shift: key.shift)]
            if twin?.isLetter == true { return true }
        }
    }
    return false
}

func dictionaryLanguage(for layout: Layout) -> String? {
    guard let raw = layout.languages.first else { return nil }
    let code = String(raw.prefix(2))
    return NSSpellChecker.shared.availableLanguages.contains(code) ? code : nil
}

/// Строгая проверка по системному словарю.
///
/// Важно: на строке с пунктуацией внутри ("k.,k.") NSSpellChecker не находит слов
/// и рапортует «ошибок нет». Принять это за успех — значит однажды подменить
/// нормальный текст мусором, поэтому такие строки словом не считаем вовсе.
private var spellCache: [String: Bool] = [:]

func isRealWord(_ word: String, language: String) -> Bool {
    guard !word.isEmpty, word.allSatisfy({ $0.isLetter }) else { return false }
    // Выученное у пользователя весомее словаря: это его собственное решение.
    if LearnedWords.shared.contains(word, language: language) { return true }

    let key = language + ":" + word
    if let known = spellCache[key] { return known }
    let range = NSSpellChecker.shared.checkSpelling(
        of: word, startingAt: 0, language: language,
        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    let result = range.location == NSNotFound
    if spellCache.count > 5000 { spellCache.removeAll() }
    spellCache[key] = result
    return result
}

/// Первый запрос к словарю грузит его с диска и может занять десятки миллисекунд.
/// В колбэке перехвата такая пауза стоит отключения тапа системой, поэтому греем заранее.
func warmUpDictionaries(_ layouts: [Layout]) {
    for layout in layouts {
        guard let language = dictionaryLanguage(for: layout) else { continue }
        _ = isRealWord(language == "ru" ? "тест" : "test", language: language)
    }
}

/// Почта, домен или ссылка: словарь про них ничего не знает, но структура говорит сама за себя.
func looksLikeAddress(_ text: String) -> Bool {
    let patterns = [
        "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$",          // почта
        "^(https?://|www\\.)[A-Za-z0-9./?&=_%+-]+$",                  // ссылка
        "^[A-Za-z0-9-]+\\.(com|ru|org|net|io|dev|app|me|cc)$",        // домен
    ]
    return patterns.contains { pattern in
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Частотные слова в одну-две буквы. Для них системный словарь не судья: он одинаково
/// признаёт и «не», и «фу», и «иг», и «дн», поэтому по словарю коротким словом оказывается
/// почти любая пара букв. Здесь — только те, ради которых правило и вводилось.
private let commonShortWords: [String: Set<String>] = [
    "ru": ["я", "в", "к", "с", "у", "о", "а", "и",
           "не", "но", "по", "за", "на", "от", "до", "то", "из", "об", "во", "со", "ко",
           "он", "мы", "вы", "ты", "их", "её", "ее", "ей", "им", "ну", "же", "ли", "бы",
           "уж", "да", "уже", "их"],
    "en": ["a", "i",
           "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is",
           "it", "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we", "ok"],
]

/// Решает, надо ли чинить слово, и если да — возвращает исправленный вариант и целевую раскладку.
func evaluate(word: String, layouts: [Layout]) -> (fixed: String, to: Layout)? {
    guard word.count >= Settings.shared.shortWordRule.minimumLength,
          word.allSatisfy({ isWordCharacter($0, layouts: layouts) }) else { return nil }
    guard let (from, to) = guessDirection(word, layouts: layouts),
          let sourceLanguage = dictionaryLanguage(for: from),
          let targetLanguage = dictionaryLanguage(for: to),
          sourceLanguage != targetLanguage else { return nil }

    // Слово нормально читается как есть — не лезем.
    guard !isRealWord(word, language: sourceLanguage) else { return nil }

    let fixed = convert(word, from: from, to: to)

    // Короткое слово проверяем по списку частотных (см. commonShortWords) либо по выученному:
    // раз человек перебил «шт» в «in» руками, это его собственное решение, а не догадка.
    if word.count < 3 {
        guard commonShortWords[targetLanguage]?.contains(fixed.lowercased()) == true
                || LearnedWords.shared.contains(fixed, language: targetLanguage)
        else { return nil }
        return (fixed, to)
    }

    // Обычный случай: результат — настоящее слово другого языка, целиком из букв.
    if isRealWord(fixed, language: targetLanguage) { return (fixed, to) }

    // Особый случай: почта, домен, ссылка. Словарём их не проверить, зато структура
    // однозначна — случайный русский текст в валидный адрес не превращается.
    if looksLikeAddress(fixed), !looksLikeAddress(word) { return (fixed, to) }

    return nil
}

/// Стирает набранное слово и печатает исправленное вместе с разделителем.
/// Разделитель мы перехватили и до экрана не пустили, поэтому стираем ровно слово.
private func ms(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }

private func applyFix(word: String, separator: Character, fixed: String, to layout: Layout) {
    let started = Date()
    defer { trace("правка «\(word)» заняла \(Int(Date().timeIntervalSince(started) * 1000)) мс") }
    let echo = fixed + String(separator)
    expectEcho(backspaces: word.count, text: echo)
    // Слово завершено разделителем — новое начинается с чистого листа. Чистим сразу:
    // отложенная чистка стирала бы первые буквы следующего слова.
    buffer = ""
    for _ in 0..<word.count { postMarked(keyBackspace) }
    let erased = Date()
    typeText(echo)
    armEchoDeadline()
    let typed = Date()
    switchInputSource(to: layout)
    trace("шаги: ⌫ \(ms(started, erased)) мс, печать \(ms(erased, typed)) мс, раскладка \(ms(typed, Date())) мс")
    lastFix = (word, fixed)
    announce(before: word, after: fixed, auto: true)
}

/// Возвращает true, если событие надо проглотить (мы введём его сами, уже после правки).
private var seenKeys = 0

// MARK: - Эхо собственной печати
//
// Свои backspace и символы возвращаются в тап и без метки: она переживает прогон не всегда.
// Раньше на это отвечали глухим таймаутом — 120 мс не копить вообще ничего. Ценой был
// пропуск начала следующего слова: пауза между разделителем и первой буквой у беглого
// набора как раз около сотни миллисекунд, так что «yfit» доезжало до проверки как «fit»,
// а это настоящее английское слово — и починка молча не срабатывала.
//
// Поэтому гасим не время, а ровно то, что напечатали сами: список ожидаемых событий в том
// порядке, в каком мы их отправили. Совпало с началом списка — наше, вычёркиваем; не
// совпало — ввод пользователя, копим как обычно.

private enum Echo {
    case key(CGKeyCode)      // наш backspace
    case char(Character)     // наш напечатанный символ
}

private var expectedEcho: [Echo] = []
private var echoDeadline = Date.distantPast

/// Объявляет, что мы сейчас напечатаем. Вызывать до отправки событий.
func expectEcho(backspaces: Int, text: String) {
    expectedEcho = Array(repeating: Echo.key(keyBackspace), count: backspaces) + text.map { Echo.char($0) }
    // Пока события не отправлены, ожиданию истекать не с чего: отсчёт начнётся в armEchoDeadline().
    // Отсчитывать отсюда — та же ошибка, что и раньше: срок истекал ещё до того, как эхо
    // возвращалось, все наши символы принимались за ввод пользователя и оседали в буфере.
    echoDeadline = .distantFuture
}

/// Запускает отсчёт: всё отправлено, дальше эхо либо придёт, либо мы перестанем его ждать.
/// Страховка нужна, иначе список однажды съест настоящий ⌫ пользователя.
///
/// Отсчёт заводим не здесь, а когда главный поток вернётся в run loop. Иначе любая долгая
/// работа сразу после отправки съедает срок целиком — ровно так и вышло со звуком починки.
func armEchoDeadline() {
    guard !expectedEcho.isEmpty else { return }
    DispatchQueue.main.async {
        guard !expectedEcho.isEmpty else { return }
        echoDeadline = Date().addingTimeInterval(0.6)
    }
}

/// true — событие наше собственное; в буфер оно не идёт, до приложения доходит как обычно.
private func consumeEcho(_ event: CGEvent) -> Bool {
    guard let head = expectedEcho.first else { return false }
    guard Date() <= echoDeadline else {
        trace("эхо: не дождался \(expectedEcho.count) событий — сбрасываю ожидание")
        expectedEcho.removeAll()
        return false
    }

    switch head {
    case .key(let expected):
        guard CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == expected else { return false }
    case .char(let expected):
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length,
                                       unicodeString: &chars)
        guard length >= 1, let scalar = Unicode.Scalar(chars[0]),
              Character(scalar) == expected else { return false }
    }
    expectedEcho.removeFirst()
    return true
}

/// Последнее набранное слово — им пользуется и ручной хоткей: копировать выделение через
/// ⌘C во многих приложениях (браузеры, Electron) не выходит, а следить за клавиатурой — всегда.
func currentTypedWord() -> String { buffer }
func setTypedBuffer(_ text: String) { buffer = text }

private func handleKeyDown(_ event: CGEvent) -> Bool {
    // Фокус в поле пароля: система включает Secure Input. Ничего не копим и не помним.
    if IsSecureEventInputEnabled() {
        buffer = ""
        return false
    }
    // Наша собственная печать (метку потеряла по дороге) — мимо буфера, но в приложение.
    if consumeEcho(event) { return false }

    let flags = event.flags
    // Клавиши с ⌥ (в т.ч. сам хоткей ⌥/) — не набор текста. Буфер НЕ трогаем: он нужен хоткею.
    if flags.contains(.maskAlternate) { return false }
    // Любой аккорд с ⌘/⌃ — это команда, а не набор текста.
    if flags.contains(.maskCommand) || flags.contains(.maskControl) {
        buffer = ""
        return false
    }

    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if resetKeys.contains(code) { buffer = ""; return false }
    if code == Int64(keyBackspace) {
        if !buffer.isEmpty { buffer.removeLast() }
        return false
    }

    var length = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length,
                                   unicodeString: &chars)
    guard length >= 1, let scalar = Unicode.Scalar(chars[0]) else { return false }
    let character = Character(scalar)

    // Слово копим всегда — даже с выключенным автоматом, ради ручного хоткея.
    if isWordCharacter(character, layouts: activeLayouts(from: autoLayouts)) {
        if !expectedEcho.isEmpty {
            trace("ввод «\(character)» пришёл посреди нашей печати (ждём ещё \(expectedEcho.count))")
        }
        buffer.append(character)
        if buffer.count > 40 { buffer.removeFirst() }   // страховка от разрастания
        return false
    }

    // Разделитель — слово закончено.
    let word = buffer
    buffer = ""
    guard character.isWhitespace || character.isPunctuation || character.isSymbol
    else { return false }
    // Автоматически чиним только если автомат включён; следить за словом — всё равно следим.
    guard Settings.shared.autoEnabled else { return false }
    guard !word.isEmpty else { return false }
    guard let (fixed, target) = evaluate(word: word, layouts: activeLayouts(from: autoLayouts))
    else {
        trace("авто: слово «\(word)» — оставляю как есть")
        return false
    }
    trace("авто: слово «\(word)» -> «\(fixed)»")

    // Из колбэка тапа выходим быстро: правку делаем следующим тиком главного цикла.
    // Сам разделитель проглатываем и допечатаем его в конце — иначе он встанет в текст
    // раньше правки и его пришлось бы стирать отдельным backspace.
    DispatchQueue.main.async { applyFix(word: word, separator: character, fixed: fixed, to: target) }
    return true
}

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // Свои же события пропускаем мимо — иначе автозамена зациклится сама на себе.
    if event.getIntegerValueField(.eventSourceUserData) == selfMarker {
        // Вычёркиваем их из ожидаемого эха здесь же: иначе список доживёт до таймаута
        // и успеет принять за своё что-нибудь из настоящего ввода.
        if type == .keyDown { _ = consumeEcho(event) }
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .keyDown:
        if handleKeyDown(event) { return nil }   // проглочено: введём сами после правки
    case .flagsChanged:
        handleFlagsChanged(event)
    case .leftMouseDown, .rightMouseDown:
        buffer = ""            // курсор уехал — слово больше не наше
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        trace("система отключила тап (\(type.rawValue)) — включаю обратно")
        if let tap = activeTap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private var activeTap: CFMachPort?

/// Тап не выключаем никогда: он нужен и для двойного Shift. Автомат — отдельный флаг.
var isAutoModeEnabled: Bool { Settings.shared.autoEnabled }

func setAutoMode(enabled: Bool) {
    Settings.shared.autoEnabled = enabled
    buffer = ""
}

/// Что вызвать по двойному Shift. Ставится демоном.
var onDoubleShift: (() -> Void)?
private var lastShiftPress: Date?
private var shiftWasDown = false

/// Двойное нажатие Shift подряд — привычный по Punto Switcher жест.
private func handleFlagsChanged(_ event: CGEvent) {
    let isDown = event.flags.contains(.maskShift)
    defer { shiftWasDown = isDown }
    guard Settings.shared.useDoubleShift, isDown, !shiftWasDown else { return }

    let now = Date()
    if let previous = lastShiftPress, now.timeIntervalSince(previous) < 0.4 {
        lastShiftPress = nil
        buffer = ""
        DispatchQueue.main.async { onDoubleShift?() }
    } else {
        lastShiftPress = now
    }
}

/// Поднимает наблюдение за клавиатурой. Возвращает false, если система не дала тап.
func startAutoMode(layouts: [Layout]) -> Bool {
    autoLayouts = layouts

    let mask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,          // перехватываем: разделитель придерживаем до правки
        eventsOfInterest: CGEventMask(mask),
        callback: tapCallback,
        userInfo: nil
    ) else { return false }

    warmUpDictionaries(layouts)
    trace("тап создан, раскладок: \(layouts.count), автомат: \(Settings.shared.autoEnabled)")
    activeTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}
