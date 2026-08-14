import Cocoa

// MARK: - Слова, выученные у пользователя
//
// Системный словарь не знает имён собственных, названий и жаргона — именно они и остаются
// непочиненными. Но каждая ручная перебивка это осознанное решение человека: он сказал,
// каким должно быть слово. Запоминаем — и дальше автомат справляется сам.

final class LearnedWords {
    static let shared = LearnedWords()

    /// язык -> слова в нижнем регистре
    private var words: [String: Set<String>] = [:]
    private let url: URL

    private init() {
        url = dataDirectory().appendingPathComponent("learned.json")

        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: [String]].self, from: data) {
            words = stored.mapValues(Set.init)
        }
    }

    func contains(_ word: String, language: String) -> Bool {
        words[language]?.contains(word.lowercased()) ?? false
    }

    var count: Int { words.values.reduce(0) { $0 + $1.count } }

    func list(language: String) -> [String] { (words[language] ?? []).sorted() }

    /// Есть ли в тексте хоть одно выученное слово этого языка.
    func containsAny(_ text: String, language: String) -> Bool {
        wordsIn(text).contains { contains($0, language: language) }
    }

    /// Разбивает исправленный текст на слова и запоминает те, которых словарь не знает.
    func learn(_ text: String, language: String) {
        var added = false
        for word in wordsIn(text) where !isRealWord(word, language: language) {
            words[language, default: []].insert(word.lowercased())
            added = true
            trace("выучил «\(word)» как \(language)")
        }
        if added { save() }
    }

    /// Пользователь перебил обратно — значит выучили зря, забываем.
    func forget(_ text: String, language: String) {
        var removed = false
        for word in wordsIn(text) where contains(word, language: language) {
            words[language]?.remove(word.lowercased())
            removed = true
            trace("забыл «\(word)» из \(language)")
        }
        if removed { save() }
    }

    func removeAll() {
        words.removeAll()
        save()
    }

    /// Только буквенные куски длиной от трёх: цифры, знаки и обрывки запоминать незачем.
    /// Порог тот же, с какого автомат вообще берётся за слово: учить то, что он потом
    /// не сможет применить, бессмысленно. Ниже двух букв не опускаемся — однобуквенные
    /// закрыты списком частотных, а урок из одной буквы слишком легко дать случайно.
    private func wordsIn(_ text: String) -> [String] {
        let minimum = max(2, Settings.shared.shortWordRule.minimumLength)
        return text.split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= minimum }
    }

    private func save() {
        let plain = words.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(plain) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Запоминает результат ручной перебивки: что получилось — верно, что было — ошибка.
/// Последняя ручная перебивка. По ней отличаем настоящую отмену от повторного нажатия.
private var lastManualFix: (before: String, after: String)?

func learnFromManualFix(before: String, after: String, from: Layout, to: Layout) {
    guard let sourceLanguage = dictionaryLanguage(for: from),
          let targetLanguage = dictionaryLanguage(for: to) else { return }

    // Отмена — это возврат ровно того, что мы только что починили: «Ощкф» -> «Jora» -> «Ощкф».
    // Раньше отменой считалась любая перебивка слова, которое когда-то выучили. Стоило нажать
    // хоткей второй раз — посмотреть результат, промахнуться мимо нужного слова — и урок
    // стирался. Отсюда и брались слова, которые приходится переключать руками снова и снова.
    if let last = lastManualFix, last.after == before, last.before == after {
        LearnedWords.shared.forget(before, language: sourceLanguage)
        lastManualFix = nil
        return
    }

    // Перебили нормальное слово в бессмыслицу — это разовое решение, а не урок. Выучив
    // «ghbdtn» как английское слово, автомат больше никогда не починил бы его в «привет».
    if isRealWord(before, language: sourceLanguage),
       !isRealWord(after, language: targetLanguage) {
        lastManualFix = (before, after)
        return
    }

    LearnedWords.shared.learn(after, language: targetLanguage)
    // Абракадабру, которую починили, из словаря убираем: если она туда когда-то попала,
    // автомат считал её настоящим словом и обходил стороной.
    LearnedWords.shared.forget(before, language: sourceLanguage)
    lastManualFix = (before, after)
}
