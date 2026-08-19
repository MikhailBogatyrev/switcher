import Foundation
import Carbon
import Cocoa

// MARK: - Раскладка, вытащенная из системы

/// Таблица одной клавиатурной раскладки: символ <-> позиция клавиши.
struct Layout {
    let id: String
    let name: String
    let source: TISInputSource
    /// Коды языков раскладки ("ru", "en") — по ним выбирается словарь для проверки.
    let languages: [String]
    /// символ -> (keycode, нужен ли shift)
    let charToKey: [Character: (code: UInt16, shift: Bool)]
    /// (keycode, shift) -> символ
    let keyToChar: [Key: Character]

    struct Key: Hashable { let code: UInt16; let shift: Bool }
}

/// Читает уникод-таблицу раскладки и разворачивает её в оба направления.
func readLayout(_ source: TISInputSource) -> Layout? {
    guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
          let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName),
          let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }

    let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
    let name = Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String
    let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data

    var languages: [String] = []
    if let langsRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
        languages = (Unmanaged<CFArray>.fromOpaque(langsRef).takeUnretainedValue() as? [String]) ?? []
    }

    var charToKey: [Character: (UInt16, Bool)] = [:]
    var keyToChar: [Layout.Key: Character] = [:]

    data.withUnsafeBytes { raw in
        guard let layoutPtr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
        else { return }

        // Только основной блок клавиш — модификаторы и функциональные нам не нужны.
        for code in UInt16(0)...UInt16(50) {
            for shift in [false, true] {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)

                let status = UCKeyTranslate(
                    layoutPtr,
                    code,
                    UInt16(kUCKeyActionDown),
                    shift ? 2 : 0,              // (shiftKey >> 8) & 0xFF
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length == 1 else { continue }

                let scalar = chars[0]
                // Отбрасываем управляющие символы (Tab, Return, Escape...).
                guard scalar >= 32, scalar != 127,
                      let unicode = Unicode.Scalar(scalar) else { continue }
                let char = Character(unicode)

                let key = Layout.Key(code: code, shift: shift)
                keyToChar[key] = char
                // Первое попадание выигрывает: без shift приоритетнее.
                if charToKey[char] == nil { charToKey[char] = (code, shift) }
            }
        }
    }

    guard !charToKey.isEmpty else { return nil }
    return Layout(id: id, name: name, source: source, languages: languages,
                  charToKey: charToKey, keyToChar: keyToChar)
}

/// Все включённые пользователем раскладки (input methods без uchr-таблицы отсеиваются).
func enabledLayouts() -> [Layout] {
    let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else { return [] }
    return list.compactMap(readLayout)
}

// MARK: - Конвертация

/// Перебивает текст так, будто те же клавиши нажали в другой раскладке.
/// Символы, которых нет в исходной раскладке (цифры, пробел, эмодзи), проходят как есть.
/// Редакторы на лету заменяют прямые кавычки и дефисы на типографские, а таких символов
/// в раскладке нет — без этой таблицы «почта"gmail.com» не превратится в «почта@gmail.com».
let typographic: [Character: Character] = [
    "«": "\"", "»": "\"", "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"",
    "\u{2018}": "'", "\u{2019}": "'", "—": "-", "–": "-",
]

func convert(_ text: String, from: Layout, to: Layout) -> String {
    String(text.map { character in
        let char = from.charToKey[character] == nil
            ? (typographic[character] ?? character) : character
        guard let key = from.charToKey[char],
              let mapped = to.keyToChar[Layout.Key(code: key.code, shift: key.shift)]
        else { return char }
        return mapped
    })
}

/// Доля букв текста, которые вообще набираются в этой раскладке.
/// Кириллица не набирается в ABC, латиница — в Russian, поэтому метрика разделяет их начисто.
func coverage(of text: String, in layout: Layout) -> Double {
    let letters = text.filter { $0.isLetter }
    guard !letters.isEmpty else { return 0 }
    let hits = letters.filter { layout.charToKey[$0] != nil }.count
    return Double(hits) / Double(letters.count)
}

/// Угадывает, в какой раскладке текст набран и в какую его надо перебить.
func guessDirection(_ text: String, layouts: [Layout]) -> (from: Layout, to: Layout)? {
    guard layouts.count >= 2 else { return nil }
    let ranked = layouts
        .map { (layout: $0, score: coverage(of: text, in: $0)) }
        .sorted { $0.score > $1.score }
    guard let source = ranked.first, source.score > 0 else { return nil }

    // Цель — лучшая из остальных: та, что даст больше всего осмысленных символов.
    let target = ranked.dropFirst()
        .max { a, b in
            coverage(of: convert(text, from: source.layout, to: a.layout), in: a.layout)
                < coverage(of: convert(text, from: source.layout, to: b.layout), in: b.layout)
        }
    guard let target else { return nil }
    return (source.layout, target.layout)
}

// MARK: - Работа с активным приложением

let keyC: CGKeyCode = 8, keyV: CGKeyCode = 9
let keyLeft: CGKeyCode = 123, keyRight: CGKeyCode = 124
let keyBackspace: CGKeyCode = 51

/// Метка на собственных событиях, чтобы перехватчик автомата не принял их за ввод пользователя
/// и не зациклил починку сам на себе.
let selfMarker: Int64 = 0x5357_4348

/// Клавиши-модификаторы (левые и правые): ⌘ ⌥ ⌃ ⇧ и Caps.
private let modifierKeycodes: [CGKeyCode] = [54, 55, 56, 58, 59, 60, 61, 62]

/// Насильно «отпускает» модификаторы, которые пользователь физически держит.
///
/// Хоткей содержит ⌥, и пока он зажат, любое наше синтетическое нажатие наследует его:
/// ⌘C уходит как ⌘⌥C и не копирует, ⌫ — как ⌥⌫ и стирает слово. Рассылаем key-up по всем
/// модификаторам, чтобы система считала их отпущенными до того, как мы что-либо нажмём.
func forceReleaseModifiers() {
    let source = CGEventSource(stateID: .hidSystemState)
    for code in modifierKeycodes {
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = []
        up?.setIntegerValueField(.eventSourceUserData, value: selfMarker)
        up?.post(tap: .cghidEventTap)
    }
    usleep(20_000)
}

func postMarked(_ code: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        event?.flags = []          // чистим унаследованные модификаторы
        event?.setIntegerValueField(.eventSourceUserData, value: selfMarker)
        event?.post(tap: .cghidEventTap)
    }
}

/// Печатает текст напрямую в юникоде — не зависит от активной раскладки и не трогает буфер.
func typeText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
            else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: selfMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
    // .hidSystemState, а не .combinedSessionState: событие строится независимо от того,
    // какие модификаторы сейчас физически зажаты. Иначе ⌥ от хоткея подмешивается в ⌘C.
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

/// Ждёт, пока в буфере появится новое содержимое после ⌘C.
func waitForClipboard(after mark: Int, timeout: TimeInterval = 0.4) -> String? {
    let pasteboard = NSPasteboard.general
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if pasteboard.changeCount != mark {
            return pasteboard.string(forType: .string)
        }
        usleep(15_000)
    }
    return nil
}

/// Текущая раскладка по её идентификатору.
func currentLayoutID() -> String? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let idRef = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
}

/// Когда в тексте нет букв (только символы/цифры), направление по буквам не определить —
/// а перебивать всё равно бывает нужно: `$` и `%` сидят на одной клавише, и в русской
/// раскладке клавиша доллара даёт `%`. Берём исходной текущую раскладку, целью — другую.
func directionFromCurrentLayout(_ layouts: [Layout]) -> (from: Layout, to: Layout)? {
    let active = activeLayouts(from: layouts)
    guard active.count >= 2 else { return nil }
    let currentID = currentLayoutID()
    let from = active.first { $0.id == currentID } ?? active[0]
    let to = active.first { $0.id != from.id } ?? active[0]
    return (from, to)
}

/// Просто переключает раскладку на другую активную — когда перебивать нечего (цифры, символы),
/// но пользователь всё равно нажал хоткей, чтобы сменить язык ввода.
func toggleKeyboardLayout(_ layouts: [Layout]) {
    let active = activeLayouts(from: layouts)
    guard active.count >= 2 else { return }
    let current = currentLayoutID()
    let next = active.first { $0.id != current } ?? active[0]
    switchInputSource(to: next)
    trace("перебивать нечего — просто переключил раскладку на \(next.name)")
}

/// TISSelectInputSource нередко игнорируется с первого раза, если дёрнуть его сразу
/// после вставки, поэтому переключение приходится проверять и повторять.
///
/// Ждать между попытками через usleep нельзя: перехватчик клавиатуры сидит на главном
/// run loop, и пока мы спим прямо в нём, тап не обслуживается — система его отключает,
/// а набранные в этот момент клавиши до нас не доходят. Отсюда и брались пропавшие буквы
/// и слова, мимо которых починка проходила молча. Поэтому паузы — асинхронные:
/// главный поток между попытками возвращается в run loop и продолжает разбирать ввод.
func switchInputSource(to layout: Layout, attempt: Int = 0) {
    TISSelectInputSource(layout.source)
    guard attempt < 2 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        if currentLayoutID() == layout.id { return }
        trace("переключение раскладки не подтвердилось (попытка \(attempt + 1))")
        switchInputSource(to: layout, attempt: attempt + 1)
    }
}

/// Снимок буфера обмена по всем типам, а не только по тексту:
/// иначе после починки из буфера пропадёт скопированная картинка или форматированный кусок.
func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        var stored: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) { stored[type] = data }
        }
        return stored
    }
}

func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let items: [NSPasteboardItem] = snapshot.compactMap { stored in
        guard !stored.isEmpty else { return nil }
        let item = NSPasteboardItem()
        for (type, data) in stored { item.setData(data, forType: type) }
        return item
    }
    if !items.isEmpty { pasteboard.writeObjects(items) }
}

/// Копирует ТОЛЬКО настоящее выделение через ⌘C — по факту изменения буфера обмена.
private func copyRealSelection() -> String? {
    let mark = NSPasteboard.general.changeCount
    postKey(keyC, flags: .maskCommand)
    guard let text = waitForClipboard(after: mark), !text.isEmpty else { return nil }
    return text
}

/// Сфокусированный UI-элемент системы.
private func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                        &focused) == .success else { return nil }
    return (focused as! AXUIElement)
}

/// Читает НАСТОЯЩЕЕ выделение через Accessibility: сначала проверяем длину диапазона, и только
/// если она > 0, берём текст. Это отсекает случай «нет выделения, а поле вернуло весь текст».
private func selectionViaAX() -> (element: AXUIElement, text: String)? {
    guard let element = focusedElement() else { return nil }

    var rangeValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                     &rangeValue) == .success, let rv = rangeValue {
        var range = CFRange()
        if AXValueGetValue(rv as! AXValue, .cfRange, &range), range.length == 0 { return nil }
    }
    var textValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                        &textValue) == .success,
          let text = textValue as? String, !text.isEmpty else { return nil }
    return (element, text)
}

/// Заменяет выделение прямо через Accessibility — надёжнее ⌘V и печати в Electron/браузерах.
private func replaceSelectionViaAX(_ element: AXUIElement, with text: String) -> Bool {
    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                 text as CFTypeRef) == .success
}

private func paste(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    postKey(keyV, flags: .maskCommand)
}

/// Заменяет активное выделение, печатая новый текст напрямую.
///
/// Раньше здесь был ⌘V из буфера — и он давал гонку: вставка успевала раньше, чем в буфер
/// ложился новый текст, отсюда дубли вроде «exampleexample». Прямая печать этого лишена;
/// выделение перед ней снимаем Delete, чтобы не зависеть от того, заменит его ввод или нет.
private func replaceSelection(with text: String) {
    expectEcho(backspaces: 1, text: text)
    buffer = ""
    postMarked(keyBackspace)   // один backspace удаляет всё выделение целиком
    usleep(20_000)
    typeText(text)
    armEchoDeadline()
}

/// Решает, надо ли трогать раскладку, по выбранному правилу.
private func shouldSwitchLayout(before: String, after: String, layouts: [Layout]) -> Bool {
    switch Settings.shared.layoutSwitchRule {
    case .always:
        return true
    case .ifAnythingChanged:
        return before != after
    case .ifTailChanged:
        // Сравниваем последние слова: починился ли именно тот кусок, где сейчас курсор.
        let beforeTail = tokenize(before, layouts: layouts).last { $0.contains { $0.isLetter } }
        let afterTail = tokenize(after, layouts: layouts).last { $0.contains { $0.isLetter } }
        return beforeTail != afterTail
    }
}

/// Хоткей. Есть выделение — перебиваем его целиком, доверяя выбору пользователя.
/// Нет — поступаем по выбранному режиму: фраза, последнее слово или ничего.
/// Пошаговая запись работы хоткея. Включается переменной среды SWITCHER_TRACE=1:
/// когда «ничего не происходит», только она и отвечает, на каком шаге всё встало.
///
/// Проверка переменной здесь не для красоты. Без неё запись шла всегда, и в trace.log
/// оседало каждое набранное слово: за одиннадцать дней работы — 18 882 строки открытым
/// текстом. Это не журнал починок (тот виден в меню и ограничен 200 записями), а полный
/// список того, что человек печатал. Такому файлу неоткуда взяться по умолчанию.
private let traceEnabled = ProcessInfo.processInfo.environment["SWITCHER_TRACE"] == "1"

func trace(_ message: String) {
    guard traceEnabled else { return }
    let file = dataDirectory().appendingPathComponent("trace.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp)  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }
}

private var lastAccessWarning = Date.distantPast

/// Без Accessibility нельзя ни скопировать выделение, ни вставить результат.
/// Молчать в этом случае нельзя: снаружи это выглядит как «программа сломана».
private func warnNoAccess() -> Bool {
    guard !AXIsProcessTrusted() else { return false }
    guard Date().timeIntervalSince(lastAccessWarning) > 20 else { return true }
    lastAccessWarning = Date()
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Switcher не имеет доступа к Универсальному доступу"
    alert.informativeText = """
        Сочетание клавиш нажато, но без этого доступа программа не может ни скопировать         выделение, ни вставить исправленный текст.

        Откройте Системные настройки → Конфиденциальность и безопасность → Универсальный         доступ и включите Switcher. Если он там уже есть — удалите его кнопкой «−»         и добавьте заново: после обновления программы старая запись перестаёт действовать.
        """
    alert.addButton(withTitle: "Открыть настройки")
    alert.addButton(withTitle: "Позже")
    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    return true
}

func fixSelection(layouts allLayouts: [Layout]) {
    if warnNoAccess() { return }
    let layouts = activeLayouts(from: allLayouts)
    trace("--- хоткей нажат, раскладок активно: \(layouts.count) [\(layouts.map(\.name).joined(separator: ", "))]")
    let mode = Settings.shared.manualMode
    forceReleaseModifiers()

    // 1. Настоящее выделение ЧИТАЕМ через Accessibility (надёжно даже в Electron), а заменяем
    //    синтетическими клавишами — backspace стирает выделение, печать вводит правку. AX-запись
    //    в Electron рапортует «успех», но на деле ничего не меняет, поэтому ей не доверяем.
    if let (_, selected) = selectionViaAX() {
        trace("выделение (AX): «\(selected)»")
        let direction = guessDirection(selected, layouts: layouts)
            ?? directionFromCurrentLayout(layouts)
        guard let (from, to) = direction else { toggleKeyboardLayout(layouts); return }
        let fixed = convert(selected, from: from, to: to)
        guard fixed != selected else { toggleKeyboardLayout(layouts); return }
        replaceSelection(with: fixed)
        if shouldSwitchLayout(before: selected, after: fixed, layouts: layouts) {
            switchInputSource(to: to)
        }
        learnFromManualFix(before: selected, after: fixed, from: from, to: to)
        announce(before: selected, after: fixed, auto: false)
        return
    }

    // 2. Настоящее выделение через ⌘C — для приложений без поддержки AX-записи.
    let snapshot = savePasteboard()
    if let selected = copyRealSelection() {
        trace("выделение (⌘C): «\(selected)»")
        applyManualFix(text: selected, viaSelection: true, layouts: layouts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restorePasteboard(snapshot) }
        return
    }
    restorePasteboard(snapshot)

    guard mode != .disabled else { return }

    // «Последнее слово» — только по слежению за клавиатурой. Прямая печать работает в любом
    // приложении, потому что не зависит ни от ⌘C, ни от выделения.
    if mode == .lastWord {
        let typed = currentTypedWord()
        trace("слежение: «\(typed)»")
        guard !typed.isEmpty else { toggleKeyboardLayout(layouts); return }
        applyManualFix(text: typed, viaSelection: false, layouts: layouts)
        return
    }

    // Жадный режим: выделяем строку до курсора и правим её кривой хвост через ⌘C.
    let snapshot2 = savePasteboard()
    postKey(keyLeft, flags: [.maskCommand, .maskShift])
    usleep(60_000)

    guard let grabbed = copyRealSelection() else {
        postKey(keyRight, flags: [])
        toggleKeyboardLayout(layouts)
        restorePasteboard(snapshot2)
        return
    }
    trace("захвачено строкой: «\(grabbed)»")

    guard let (repaired, _) = repairLine(grabbed, layouts: layouts), repaired != grabbed else {
        postKey(keyRight, flags: [])
        toggleKeyboardLayout(layouts)
        restorePasteboard(snapshot2)
        return
    }
    replaceSelection(with: repaired)
    if let (from, to) = guessDirection(grabbed, layouts: layouts) {
        learnFromManualFix(before: grabbed, after: repaired, from: from, to: to)
        if shouldSwitchLayout(before: grabbed, after: repaired, layouts: layouts) {
            switchInputSource(to: to)
        }
    }
    announce(before: grabbed, after: repaired, auto: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restorePasteboard(snapshot2) }
}

/// Единая точка перебивки: чинит текст, печатает результат, переключает раскладку.
/// `viaSelection` — заменять выделение (delete+type) или переписывать последнее слово по слежению.
private func applyManualFix(text: String, viaSelection: Bool, layouts: [Layout]) {
    let direction = guessDirection(text, layouts: layouts) ?? directionFromCurrentLayout(layouts)
    guard let (from, to) = direction else { toggleKeyboardLayout(layouts); return }

    let fixed = convert(text, from: from, to: to)
    trace("перебивка: «\(text)» -> «\(fixed)» (\(from.name)→\(to.name))")
    guard fixed != text else { toggleKeyboardLayout(layouts); return }

    if viaSelection {
        replaceSelection(with: fixed)
    } else {
        // Гасим ровно своё эхо, иначе синтетические backspace/символы съедят буфер.
        expectEcho(backspaces: text.count, text: fixed)
        setTypedBuffer(fixed)          // повторное нажатие вернёт обратно — toggle
        for _ in 0..<text.count { postMarked(keyBackspace) }
        usleep(15_000)
        typeText(fixed)
        armEchoDeadline()
    }
    if shouldSwitchLayout(before: text, after: fixed, layouts: layouts) {
        switchInputSource(to: to)
    }
    learnFromManualFix(before: text, after: fixed, from: from, to: to)
    announce(before: text, after: fixed, auto: false)
}

// MARK: - Демон

/// Перехват уже поднят? Права могут появиться позже, поэтому состояние отдельное.
var inputCaptureReady = false

/// Поднимает хоткей и перехват. Вызывается либо сразу, либо в момент, когда выданы права.
@discardableResult
func activateInputCapture() -> Bool {
    guard !inputCaptureReady, AXIsProcessTrusted() else { return inputCaptureReady }
    onDoubleShift = { fixSelection(layouts: daemonLayouts) }
    guard startAutoMode(layouts: daemonLayouts) else { return false }
    inputCaptureReady = true
    return true
}

/// Не даёт запуститься второму экземпляру. Автозапуск может сработать сразу двумя путями
/// (LaunchAgent + Login Item), и без этой проверки в строке меню появляются две иконки.
/// Оставляем самый ранний процесс, все последующие завершаем.
func terminateIfAlreadyRunning() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard running.count > 1 else { return }
    let oldest = running.min {
        ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
    }
    if oldest?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        exit(0)   // мы — лишний экземпляр
    }
}

func runDaemon(layouts: [Layout], auto: Bool) {
    terminateIfAlreadyRunning()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    daemonLayouts = layouts
    Settings.shared.autoEnabled = auto

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        fixSelection(layouts: daemonLayouts)
        return noErr
    }, 1, &spec, nil, nil)

    // Хоткей занимаем сразу: он работает без Accessibility, и если этого не сделать,
    // сочетание уйдёт в приложение и вставит символ — худшая из возможных реакций.
    registerHotkey()

    // Иконку показываем всегда и сразу — даже без прав. Иначе выдавать права не за чем:
    // программы на экране не видно, и непонятно, запустилась ли она вообще.
    statusBar = StatusBarController(layouts: layouts)

    if !activateInputCapture() {
        // Просим доступ и ЖДЁМ его, а не выходим: система выдаёт права уже работающему
        // приложению, и перезапускать его вручную не должно требоваться.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        print("Нет доступа к Универсальному доступу. Включите Switcher в списке — программа подхватит это сама.")

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard activateInputCapture() else { return }
            timer.invalidate()
            statusBar?.refresh()
            print("Доступ получен, перехват включён.")
        }
    }

    print("switcher запущен. \(Settings.shared.hotkey.title) — перебить выделение или хвост строки.")
    app.run()
}

var daemonLayouts: [Layout] = []
var statusBar: StatusBarController?
private var hotKeyRef: EventHotKeyRef?

/// Пере-регистрирует хоткей — вызывается и при старте, и после смены сочетания в меню.
func registerHotkey() {
    if let existing = hotKeyRef { UnregisterEventHotKey(existing); hotKeyRef = nil }
    let choice = Settings.shared.hotkey
    let hotKeyID = EventHotKeyID(signature: OSType(0x53574348), id: 1) // 'SWCH'
    let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, hotKeyID,
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
    if status != noErr {
        print("Сочетание \(choice.title) занято другой программой (код \(status)).")
    }
}

// MARK: - CLI

let layouts = enabledLayouts()
// LaunchServices подсовывает -psn_0_… при запуске через open — это не наш аргумент.
let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") }

// Запуск двойным щелчком по .app: аргументов нет, но человек ждёт работающую программу,
// а не справку. Отличаем по наличию бандла.
if args.isEmpty, Bundle.main.bundleIdentifier != nil {
    runDaemon(layouts: enabledLayouts(), auto: true)
    exit(0)
}

if args.first == "--daemon" || args.first == "--auto" {
    runDaemon(layouts: layouts, auto: args.first == "--auto")
    exit(0)
}

// Сухой прогон решателя: показывает, тронул бы автомат это слово или нет.
// Сухой прогон жадной починки строки.
if args.first == "--line" {
    let line = args.dropFirst().joined(separator: " ")
    if let (repaired, target) = repairLine(line, layouts: layouts) {
        print("\(line)\n  -> \(repaired)   [\(target.name)]")
    } else {
        print("\(line)\n  -> без изменений")
    }
    exit(0)
}

// Научить слову заранее, не дожидаясь случая перебить его руками.
if args.first == "--teach" {
    for word in args.dropFirst() {
        guard let (from, to) = guessDirection(word, layouts: layouts) else {
            print("\(word): не понял раскладку")
            continue
        }
        let fixed = convert(word, from: from, to: to)
        learnFromManualFix(before: word, after: fixed, from: from, to: to)
        print("\(word) -> \(fixed): запомнено")
    }
    exit(0)
}

if args.first == "--forget-all" {
    LearnedWords.shared.removeAll()
    print("выученные слова забыты")
    exit(0)
}

if args.first == "--check" {
    for word in args.dropFirst() {
        if case .fix(let fixed, let target) = evaluate(word: word, layouts: layouts) {
            print("\(word) -> \(fixed)   [\(target.name)]")
        } else {
            print("\(word) -> без изменений")
        }
    }
    exit(0)
}

if args.first == "--layouts" || args.isEmpty {
    print("Включённые раскладки:")
    for layout in layouts {
        print("  \(layout.name)  [\(layout.id)]  \(layout.charToKey.count) символов")
    }
    if args.isEmpty {
        print("\nИспользование: switcher \"ghtlgjxbnf.\"")
    }
    exit(0)
}

let input = args.joined(separator: " ")
guard let (from, to) = guessDirection(input, layouts: layouts) else {
    FileHandle.standardError.write("Не удалось определить раскладку\n".data(using: .utf8)!)
    exit(1)
}
print(convert(input, from: from, to: to))
