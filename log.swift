import Cocoa
import UserNotifications

// MARK: - Папка с данными
//
// Здесь лежит всё, что программа знает о пользователе: выученные слова, журнал починок,
// пошаговая запись работы. Это набранный человеком текст, и по умолчанию macOS создала бы
// папку с правами 755 — читать её смог бы любой другой аккаунт на машине. Поэтому 700:
// данные никуда не уходят и остаются доступны только владельцу.
func dataDirectory() -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("switcher", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    // Папка могла остаться с прошлых версий — приводим права в порядок и у неё.
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

// MARK: - Журнал починок и обратная связь

struct LogEntry: Codable {
    /// Стабильный номер записи. По позиции в списке ориентироваться нельзя:
    /// пока меню открыто, автомат может добавить починку и сдвинуть все индексы.
    let id: Int
    let date: Date
    let before: String
    let after: String
    let auto: Bool          // автоматическая правка или ручная по хоткею
    var correct: Bool?      // оценка пользователя: nil — не оценивал

    var short: String {
        func trim(_ text: String) -> String {
            let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 24 ? "…" + flat.suffix(23) : flat
        }
        let mark = correct == false ? "✕ " : (correct == true ? "✓ " : "")
        return "\(mark)\(trim(before)) → \(trim(after))"
    }
}

/// Журнал на диске. Нужен не для красоты: пометки «сработало неверно» — это данные,
/// по которым потом видно, какие слова ломают критерий срабатывания.
final class ConversionLog {
    static let shared = ConversionLog()

    private(set) var entries: [LogEntry] = []
    private let queue = DispatchQueue(label: "switcher.log")


    private let fileURL: URL = dataDirectory().appendingPathComponent("log.json")

    private init() { load() }

    private func load() {
        let decoder = JSONDecoder()
        // Обязано совпадать со стратегией записи, иначе разбор молча падает и журнал теряется.
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode([LogEntry].self, from: data) else { return }
        entries = stored
    }

    private func persist() {
        let snapshot = entries
        queue.async { [fileURL] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) { try? data.write(to: fileURL) }
        }
    }

    func add(before: String, after: String, auto: Bool) {
        let nextID = (entries.map(\.id).max() ?? 0) + 1
        entries.insert(LogEntry(id: nextID, date: Date(), before: before, after: after,
                                auto: auto, correct: nil), at: 0)
        if entries.count > Settings.shared.logLimit {
            entries.removeLast(entries.count - Settings.shared.logLimit)
        }
        persist()
    }

    func rate(id: Int, correct: Bool?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].correct = correct
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    /// Отдаёт JSON для сохранения — путь выбирает пользователь в системном диалоге.
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(entries)
    }

    var wrongCount: Int { entries.filter { $0.correct == false }.count }
}

// MARK: - Звук и уведомления

private var notificationsReady = false

func prepareNotifications() {
    guard Settings.shared.showNotifications, !notificationsReady else { return }
    notificationsReady = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
}

/// Звук починки. Держим один загруженный экземпляр и играем его вне главного потока.
///
/// NSSound.play() на «холодном» аудиоустройстве блокирует поток, пока оно просыпается:
/// замер на этой машине — 579 мс против 0 мс на «тёплом». Раньше звук играли прямо в
/// главном потоке, внутри правки, а на нём же сидит перехватчик клавиатуры. Пока поток
/// спал, тап не обслуживался: набранные в эту паузу буквы пропадали, а наше собственное
/// эхо возвращалось уже просроченным и оседало в буфере как пользовательский ввод.
private let feedbackQueue = DispatchQueue(label: "switcher.feedback", qos: .utility)
private let tink = NSSound(named: .init("Tink"))

private func playFixSound() {
    feedbackQueue.async {
        guard let sound = tink else { return }
        if sound.isPlaying { sound.stop() }   // подряд идущие починки не глушат друг друга
        sound.play()
    }
}

/// Сообщает пользователю о починке ровно теми способами, которые он включил.
func announce(before: String, after: String, auto: Bool) {
    ConversionLog.shared.add(before: before, after: after, auto: auto)
    recordFix(from: before, to: after)

    if Settings.shared.playSound { playFixSound() }

    guard Settings.shared.showNotifications else { return }
    prepareNotifications()
    let content = UNMutableNotificationContent()
    content.title = "Раскладка исправлена"
    content.body = "\(before) → \(after)"
    let request = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
