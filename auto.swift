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

/// Номер «поколения» ввода. Растёт всякий раз, когда набранное слово перестаёт быть нашим:
/// Enter, стрелки, щелчок мышью, аккорд с ⌘, снятый системой тап.
///
/// Нужен догоняющей правке. Она приходит на десятки миллисекунд позже разделителя, и за это
/// время человек успевает нажать Enter — сообщение уже отправлено, а наши ⌫ прилетают в
/// пустое поле и стирают что попало. Правка сверяет поколение и молча отменяется, если оно
/// сменилось. Обещание «по Enter починки нет» держится именно здесь.
private var inputEpoch = 0
private func invalidateWord() {
    buffer = ""
    inputEpoch &+= 1
}


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

/// Ответ словаря, если он известен без обращения к системе: nil — «не спрашивали».
///
/// Разделение не косметическое. Первый запрос про незнакомое слово читает словарь с диска и
/// занимает десятки миллисекунд, а колбэк перехвата обязан возвращаться мгновенно: пока он
/// думает, система вправе снять тап, и все клавиши этого окна теряются вместе с ним —
/// снаружи это выглядит как «целый кусок фразы не перебился, а через минуту всё снова
/// работает». Поэтому в колбэке спрашиваем только кеш, а промах уводим на главный поток.
func cachedRealWord(_ word: String, language: String) -> Bool? {
    guard !word.isEmpty, word.allSatisfy({ $0.isLetter }) else { return false }
    // Выученное у пользователя весомее словаря: это его собственное решение.
    if LearnedWords.shared.contains(word, language: language) { return true }
    return spellCache[language + ":" + word]
}

func isRealWord(_ word: String, language: String) -> Bool {
    if let known = cachedRealWord(word, language: language) { return known }
    let range = NSSpellChecker.shared.checkSpelling(
        of: word, startingAt: 0, language: language,
        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    let result = range.location == NSNotFound
    if spellCache.count > 5000 { spellCache.removeAll() }
    spellCache[language + ":" + word] = result
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

/// Словарь исключений для слов в один-два символа.
///
/// Системный словарь на такой длине не судья ни с одной стороны. Он одинаково «узнаёт»
/// и «не», и «фу», и «иг», и «дн», а заодно считает английским словом «bp» — из-за чего
/// «из» не чинилось никогда: проверка «слово нормально читается как есть» срабатывала
/// раньше всех остальных. Поэтому короткие слова со словарём вообще не сверяются, только
/// с этими списками, и решение читается в одну строку: набранное — слово своего языка
/// (не трогаем), перебитое — слово чужого (чиним). Одновременно в обоих списках короткое
/// слово не встречается, в этом вся идея.
let shortWordExceptions: [String: Set<String>] = [
    "ru": ["а", "в", "и", "к", "о", "с", "у", "я",
           "аж", "ах", "бы", "во", "вы", "да", "до", "ее", "её", "ей", "ею", "же", "за",
           "из", "им", "их", "ко", "ли", "мы", "на", "не", "ни", "но", "ну", "об", "он",
           "от", "ох", "по", "со", "та", "те", "то", "ту", "ты", "уж", "ум", "эй", "эх"],
    "en": ["a", "i",
           "ad", "ah", "am", "an", "as", "at", "ax", "be", "by", "do", "ex", "go", "he",
           "hi", "id", "if", "in", "is", "it", "la", "lo", "me", "my", "no", "of", "oh",
           "ok", "on", "or", "ox", "pi", "pm", "re", "so", "ta", "to", "um", "up", "us",
           "we"],
]

/// Приговор слову. Третий случай — не лень, а следствие устройства перехвата: ответ знает
/// только системный словарь, а спрашивать его в колбэке тапа нельзя (см. cachedRealWord).
enum Verdict {
    case fix(String, Layout)
    case leave
    case unknown
}

/// Короткие слова: решение целиком по спискам исключений, без словаря.
///
/// Буквенность проверяем отдельно и с обеих сторон. «,» на русской раскладке — это «б»,
/// то есть формально часть слова; без этой проверки одинокая запятая перед пробелом
/// превратилась бы в букву.
private func shortWordVerdict(word: String, fixed: String,
                              source: String, target: String, to: Layout) -> Verdict {
    guard word.allSatisfy({ $0.isLetter }), fixed.allSatisfy({ $0.isLetter }) else { return .leave }
    if shortWordExceptions[source]?.contains(word.lowercased()) == true { return .leave }
    if LearnedWords.shared.contains(word, language: source) { return .leave }
    if shortWordExceptions[target]?.contains(fixed.lowercased()) == true { return .fix(fixed, to) }
    // Раз человек перебил «шт» в «in» руками, это его собственное решение, а не догадка.
    if LearnedWords.shared.contains(fixed, language: target) { return .fix(fixed, to) }
    return .leave
}

/// Решает, надо ли чинить слово, и если да — возвращает исправленный вариант и целевую раскладку.
///
/// `allowLookup: false` — режим колбэка тапа: отвечаем только тем, что уже в кеше словаря,
/// а на промахе честно говорим `.unknown`, чтобы спросили снаружи.
func evaluate(word: String, layouts: [Layout], allowLookup: Bool = true) -> Verdict {
    guard word.count >= Settings.shared.shortWordRule.minimumLength,
          word.allSatisfy({ isWordCharacter($0, layouts: layouts) }) else { return .leave }
    guard let (from, to) = guessDirection(word, layouts: layouts),
          let sourceLanguage = dictionaryLanguage(for: from),
          let targetLanguage = dictionaryLanguage(for: to),
          sourceLanguage != targetLanguage else { return .leave }

    let fixed = convert(word, from: from, to: to)

    // Один-два символа — свой мир, со словарём не разговариваем вовсе.
    if word.count < 3 {
        return shortWordVerdict(word: word, fixed: fixed,
                                source: sourceLanguage, target: targetLanguage, to: to)
    }

    // Слово нормально читается как есть — не лезем.
    if let known = cachedRealWord(word, language: sourceLanguage) {
        if known { return .leave }
    } else {
        guard allowLookup else { return .unknown }
        if isRealWord(word, language: sourceLanguage) { return .leave }
    }

    // Обычный случай: результат — настоящее слово другого языка, целиком из букв.
    if let known = cachedRealWord(fixed, language: targetLanguage) {
        if known { return .fix(fixed, to) }
    } else {
        guard allowLookup else { return .unknown }
        if isRealWord(fixed, language: targetLanguage) { return .fix(fixed, to) }
    }

    // Особый случай: почта, домен, ссылка. Словарём их не проверить, зато структура
    // однозначна — случайный русский текст в валидный адрес не превращается.
    if looksLikeAddress(fixed), !looksLikeAddress(word) { return .fix(fixed, to) }

    return .leave
}

/// Стирает набранное слово и печатает исправленное вместе с разделителем.
/// Разделитель мы перехватили и до экрана не пустили, поэтому стираем ровно слово.
private func ms(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }

/// - `separator`: символ, завершивший слово, — его допечатываем сами. `nil` для Enter:
///   он не символ, и возвращается отдельным нажатием уже после правки.
/// - `alreadyOnScreen`: слово успело уехать на экран вместе со всем, что человек набрал
///   следом. Тогда стирать надо и это тоже.
private func applyFix(word: String, separator: Character?, fixed: String, to layout: Layout,
                      alreadyOnScreen: Bool = false) {
    let started = Date()
    defer { trace("правка «\(word)» заняла \(Int(Date().timeIntervalSince(started) * 1000)) мс") }
    // Догоняющая правка: разделитель до экрана уже доехал, да и человек мог успеть начать
    // следующее слово. Стираем всё это и печатаем заново — иначе правка встанет посреди
    // набранного. При обычной правке стирать нечего: разделитель мы придержали.
    let pending = alreadyOnScreen ? buffer : ""
    let separatorOnScreen = alreadyOnScreen && separator != nil
    let erase = word.count + (separatorOnScreen ? 1 : 0) + pending.count
    let echo = fixed + (separator.map(String.init) ?? "") + pending
    expectEcho(backspaces: erase, text: echo)
    // Слово завершено разделителем — новое начинается с чистого листа. Чистим сразу:
    // отложенная чистка стирала бы первые буквы следующего слова. Набранное следом
    // возвращаем как есть, поэтому буфер догоняющей правки переживает её нетронутым.
    if !alreadyOnScreen { buffer = "" }
    for _ in 0..<erase { postMarked(keyBackspace) }
    let erased = Date()
    typeText(echo)
    armEchoDeadline()
    let typed = Date()
    // Раскладку двигаем только на словах от трёх букв. «фе» -> «at» — слишком слабый повод
    // увести всю клавиатуру на английский: человек пишет русскую фразу, а следующие слова
    // после такого переезда выходят латиницей, и чинить приходится уже их.
    if word.count >= 3 { switchInputSource(to: layout) }
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
        invalidateWord()
        return false
    }
    // Наша собственная печать (метку потеряла по дороге) — мимо буфера, но в приложение.
    if consumeEcho(event) { return false }

    let flags = event.flags
    // Клавиши с ⌥ (в т.ч. сам хоткей ⌥/) — не набор текста. Буфер НЕ трогаем: он нужен хоткею.
    if flags.contains(.maskAlternate) { return false }
    // Любой аккорд с ⌘/⌃ — это команда, а не набор текста.
    if flags.contains(.maskCommand) || flags.contains(.maskControl) {
        invalidateWord()
        return false
    }

    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if code == Int64(keyReturn) || code == Int64(keyNumpadReturn) {
        return handleReturn(code: CGKeyCode(code), flags: flags)
    }
    if resetKeys.contains(code) { invalidateWord(); return false }
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
    let layouts = activeLayouts(from: autoLayouts)
    // В колбэке спрашиваем только кеш: обращение к системному словарю здесь стоит тапа.
    switch evaluate(word: word, layouts: layouts, allowLookup: false) {
    case .fix(let fixed, let target):
        trace("авто: слово «\(word)» -> «\(fixed)»")
        // Из колбэка тапа выходим быстро: правку делаем следующим тиком главного цикла.
        // Сам разделитель проглатываем и допечатаем его в конце — иначе он встанет в текст
        // раньше правки и его пришлось бы стирать отдельным backspace.
        DispatchQueue.main.async {
            applyFix(word: word, separator: character, fixed: fixed, to: target)
        }
        return true
    case .leave:
        trace("авто: слово «\(word)» — оставляю как есть")
        return false
    case .unknown:
        // Слово словарю ещё не показывали. Спросим на главном потоке, а разделитель пропустим
        // сейчас: держать его — значит держать колбэк, а это ровно та задержка, из-за которой
        // система снимает перехват. Правка будет догоняющей (см. applyFix).
        let epoch = inputEpoch
        DispatchQueue.main.async {
            evaluateOffTap(word: word, separator: character, layouts: layouts, epoch: epoch)
        }
        return false
    }
}

/// Enter завершает слово не хуже пробела, но чинить после него нечего: сообщение отправлено,
/// строка закрыта, а наши ⌫ прилетят уже в пустое поле. Поэтому Enter придерживаем ровно так
/// же, как разделитель: сначала правка, потом нажатие — и уходит уже исправленное слово.
///
/// Придерживаем не всегда. Пустой буфер и слова, про которые ответ «оставить как есть» уже
/// известен, отпускают Enter немедленно: задержка отправки на ровном месте не нужна, а
/// синтетическое нажатие — лишний способ не отправить сообщение вовсе.
private func handleReturn(code: CGKeyCode, flags: CGEventFlags) -> Bool {
    let word = buffer
    invalidateWord()          // слово закрыто в любом случае
    guard Settings.shared.autoEnabled, !word.isEmpty else { return false }
    let layouts = activeLayouts(from: autoLayouts)
    // Поколение считаем уже после invalidateWord: сменится оно только если человек успел
    // щёлкнуть мышью или нажать что-то ещё, пока мы держим Enter. Тогда стирать нельзя —
    // курсор уже не там, — но сам Enter вернуть всё равно обязаны.
    let epoch = inputEpoch

    switch evaluate(word: word, layouts: layouts, allowLookup: false) {
    case .leave:
        trace("Enter: слово «\(word)» — оставляю как есть")
        return false
    case .fix(let fixed, let target):
        trace("Enter: слово «\(word)» -> «\(fixed)»")
        DispatchQueue.main.async {
            if inputEpoch == epoch {
                applyFix(word: word, separator: nil, fixed: fixed, to: target, alreadyOnScreen: true)
            }
            postMarked(code, flags: flags)
        }
        return true
    case .unknown:
        // Ответ знает только словарь. Спрашиваем вне колбэка, а Enter возвращаем в любом
        // случае — и когда починили, и когда чинить оказалось нечего. Проглотить его
        // насовсем значит съесть отправку сообщения.
        DispatchQueue.main.async {
            if inputEpoch == epoch,
               case .fix(let fixed, let target) = evaluate(word: word, layouts: layouts) {
                trace("Enter (вдогонку): слово «\(word)» -> «\(fixed)»")
                applyFix(word: word, separator: nil, fixed: fixed, to: target, alreadyOnScreen: true)
            } else {
                trace("Enter (вдогонку): слово «\(word)» — оставляю как есть")
            }
            postMarked(code, flags: flags)
        }
        return true
    }
}

/// Догоняющая проверка: слово уже на экране вместе с разделителем, спрашиваем словарь спокойно.
private func evaluateOffTap(word: String, separator: Character, layouts: [Layout], epoch: Int) {
    guard case .fix(let fixed, let target) = evaluate(word: word, layouts: layouts) else {
        trace("авто (вдогонку): слово «\(word)» — оставляю как есть")
        return
    }
    // Пока спрашивали словарь, человек нажал Enter, стрелку или щёлкнул мышью: стирать
    // теперь нечего и опасно — правка отменяется.
    guard inputEpoch == epoch else {
        trace("авто (вдогонку): «\(word)» — ввод ушёл дальше, правку отменяю")
        return
    }
    trace("авто (вдогонку): слово «\(word)» -> «\(fixed)»")
    applyFix(word: word, separator: separator, fixed: fixed, to: target, alreadyOnScreen: true)
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
        invalidateWord()       // курсор уехал — слово больше не наше
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // Пока тап был снят, часть клавиш прошла мимо нас: в буфере лежит огрызок слова,
        // и проверять его — значит гадать. Начинаем со следующего слова.
        trace("система отключила тап (\(type.rawValue)) — включаю обратно, буфер сброшен")
        invalidateWord()
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
