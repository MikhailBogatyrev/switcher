import Cocoa

// MARK: - Починка фразы, а не одного слова
//
// Идея взята из github.com/reg2005/langSwitcher: выделять не последнее слово, а всю строку
// до курсора и перебивать только её «кривой» хвост. Но решение о кривизне там принимается
// по смене письменности (латиница/кириллица), а этого мало — «lheu» («друг») выглядит как
// нормальное английское слово. Здесь тот же алгоритм границы, но судит системный словарь.

/// Режет строку на слова и промежутки так, что склейка кусков даёт исходную строку.
func tokenize(_ text: String, layouts: [Layout]) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inWord: Bool?

    for character in text {
        let isWord = isWordCharacter(character, layouts: layouts)
        if inWord != nil && isWord != inWord {
            tokens.append(current)
            current = ""
        }
        inWord = isWord
        current.append(character)
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

/// Похоже ли, что слово набрано не в той раскладке.
///
/// Мягче, чем `evaluate`: внутри фразы попадаются имена и термины, которых нет в словаре,
/// поэтому смены письменности достаточно — но только если само слово словарю неизвестно.
func looksWrongLayout(_ token: String, layouts: [Layout]) -> Bool {
    // Судим по «ядру» — без окаймляющей пунктуации, иначе «Привет,» не опознается словарём.
    let core = token.trimmingCharacters(in: CharacterSet.letters.inverted)
    guard core.count >= 2 else { return false }
    guard let (from, to) = guessDirection(core, layouts: layouts),
          let sourceLanguage = dictionaryLanguage(for: from),
          let targetLanguage = dictionaryLanguage(for: to),
          sourceLanguage != targetLanguage else { return false }

    // Нормальное слово своего языка не трогаем ни при каких обстоятельствах.
    if isRealWord(core, language: sourceLanguage) { return false }

    let converted = convert(core, from: from, to: to)
    if isRealWord(converted, language: targetLanguage) { return true }

    // Дальше словаря нет, остаётся смена письменности — довод слабый, поэтому принимаем
    // его только для «чистых» слов. Иначе под нож попадают package.json, README и utf-8.
    guard core.count >= 3,
          core.allSatisfy({ $0.isLetter }),
          core != core.uppercased(),
          !token.contains(where: { $0.isNumber }) else { return false }

    let sourceIsLatin = core.contains { $0.isLetter && $0.isASCII }
    let convertedIsLatin = converted.contains { $0.isLetter && $0.isASCII }
    return sourceIsLatin != convertedIsLatin
}

/// Находит, с какого места строки начинается текст в неверной раскладке.
/// Возвращает неизменяемый префикс и хвост под перебивку.
func findWrongLayoutBoundary(in text: String, layouts: [Layout]) -> (keep: String, convert: String)? {
    let tokens = tokenize(text, layouts: layouts)
    let words = tokens.enumerated().filter { $0.element.contains { $0.isLetter } }
    guard !words.isEmpty else { return nil }

    let wrongCount = words.filter { looksWrongLayout($0.element, layouts: layouts) }.count

    // Вся строка кривая — самый частый случай: человек не заметил раскладку с самого начала.
    if wrongCount == words.count { return (keep: "", convert: text) }
    guard wrongCount > 0 else { return nil }

    // Иначе идём справа налево и останавливаемся на первом нормальном слове.
    var boundary = tokens.count
    for index in stride(from: tokens.count - 1, through: 0, by: -1) {
        let token = tokens[index]
        guard token.contains(where: { $0.isLetter }) else { continue }
        if looksWrongLayout(token, layouts: layouts) {
            boundary = index
        } else {
            break
        }
    }
    guard boundary < tokens.count else { return nil }

    let keep = tokens[0..<boundary].joined()
    let tail = tokens[boundary...].joined()
    guard tail.contains(where: { $0.isLetter }) else { return nil }
    return (keep: keep, convert: tail)
}

/// Перебивает только кривой хвост строки, префикс оставляет как есть.
func repairLine(_ text: String, layouts: [Layout]) -> (text: String, to: Layout)? {
    guard let boundary = findWrongLayoutBoundary(in: text, layouts: layouts),
          let (from, to) = guessDirection(boundary.convert, layouts: layouts) else { return nil }
    let repaired = boundary.keep + convert(boundary.convert, from: from, to: to)
    guard repaired != text else { return nil }
    return (repaired, to)
}
