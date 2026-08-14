import Cocoa
import Carbon

// MARK: - Настройки, переживающие перезапуск

/// Что делает хоткей, когда ничего не выделено.
enum ManualMode: Int, CaseIterable {
    case greedy = 0     // выделить строку до курсора и починить её кривой хвост
    case lastWord = 1   // взять только слово слева от курсора
    case disabled = 2   // работать исключительно с явным выделением

    var title: String {
        switch self {
        case .greedy: return "Всю фразу до начала строки"
        case .lastWord: return "Только последнее слово"
        case .disabled: return "Ничего (только выделенное)"
        }
    }
}

/// Когда переключать саму раскладку после починки.
enum LayoutSwitchRule: Int, CaseIterable {
    case always = 0            // всегда, даже если текст не изменился
    case ifTailChanged = 1     // если починилось последнее слово
    case ifAnythingChanged = 2 // если починилось хоть что-то

    var title: String {
        switch self {
        case .always: return "Всегда"
        case .ifTailChanged: return "Если починилось последнее слово"
        case .ifAnythingChanged: return "Если починилось хоть что-то"
        }
    }
}

/// До какой длины чинить слова. Короткие неоднозначны, но в русском они же и самые частые:
/// «не», «по», «за», «и» — без них фраза остаётся наполовину кривой.
enum ShortWordRule: Int, CaseIterable {
    case off = 0          // только от трёх букв, как было
    case twoLetters = 1   // плюс двухбуквенные: yt -> не, pf -> за
    case oneLetter = 2    // плюс однобуквенные: b -> и, c -> с

    var minimumLength: Int {
        switch self {
        case .off: return 3
        case .twoLetters: return 2
        case .oneLetter: return 1
        }
    }

    var title: String {
        switch self {
        case .off: return "Нет, только от трёх букв"
        case .twoLetters: return "Да, от двух букв"
        case .oneLetter: return "Да, даже однобуквенные"
        }
    }
}

/// Заранее заданные сочетания: окна записи хоткея у нас нет, а список закрывает почти всё.
struct HotkeyChoice {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotkeyChoice] = [
        HotkeyChoice(title: "⌥ /", keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(optionKey)),
        HotkeyChoice(title: "⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        HotkeyChoice(title: "⌘ ⌥ Space", keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(optionKey | cmdKey)),
        HotkeyChoice(title: "⌃ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)),
        HotkeyChoice(title: "F13", keyCode: UInt32(kVK_F13), modifiers: 0),
    ]
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "playSound": true,
            "showNotifications": false,
            "manualMode": ManualMode.greedy.rawValue,
            "layoutSwitchRule": LayoutSwitchRule.ifAnythingChanged.rawValue,
            "hotkeyIndex": 0,
            "useDoubleShift": false,
            "autoEnabled": true,
            "shortWordRule": ShortWordRule.twoLetters.rawValue,
            "logLimit": 200,
        ])
    }

    var playSound: Bool {
        get { defaults.bool(forKey: "playSound") }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    var showNotifications: Bool {
        get { defaults.bool(forKey: "showNotifications") }
        set { defaults.set(newValue, forKey: "showNotifications") }
    }

    var manualMode: ManualMode {
        get { ManualMode(rawValue: defaults.integer(forKey: "manualMode")) ?? .greedy }
        set { defaults.set(newValue.rawValue, forKey: "manualMode") }
    }

    var layoutSwitchRule: LayoutSwitchRule {
        get { LayoutSwitchRule(rawValue: defaults.integer(forKey: "layoutSwitchRule"))
                ?? .ifAnythingChanged }
        set { defaults.set(newValue.rawValue, forKey: "layoutSwitchRule") }
    }

    /// Индекс в HotkeyChoice.all. Хранить индекс, а не коды — меньше шансов записать мусор.
    var hotkeyIndex: Int {
        get { min(max(defaults.integer(forKey: "hotkeyIndex"), 0), HotkeyChoice.all.count - 1) }
        set { defaults.set(newValue, forKey: "hotkeyIndex") }
    }

    var hotkey: HotkeyChoice { HotkeyChoice.all[hotkeyIndex] }

    var useDoubleShift: Bool {
        get { defaults.bool(forKey: "useDoubleShift") }
        set { defaults.set(newValue, forKey: "useDoubleShift") }
    }

    /// Автоматический режим: помним между запусками, чтобы не включать заново каждый раз.
    var autoEnabled: Bool {
        get { defaults.bool(forKey: "autoEnabled") }
        set { defaults.set(newValue, forKey: "autoEnabled") }
    }

    var shortWordRule: ShortWordRule {
        get { ShortWordRule(rawValue: defaults.integer(forKey: "shortWordRule")) ?? .twoLetters }
        set { defaults.set(newValue.rawValue, forKey: "shortWordRule") }
    }

    var logLimit: Int {
        get { max(defaults.integer(forKey: "logLimit"), 10) }
        set { defaults.set(newValue, forKey: "logLimit") }
    }

    /// Раскладки, исключённые пользователем из игры.
    var excludedLayoutIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedLayoutIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "excludedLayoutIDs") }
    }

    func isLayoutActive(_ layout: Layout) -> Bool { !excludedLayoutIDs.contains(layout.id) }

    func toggleLayout(_ layout: Layout) {
        var excluded = excludedLayoutIDs
        if excluded.contains(layout.id) { excluded.remove(layout.id) } else { excluded.insert(layout.id) }
        excludedLayoutIDs = excluded
    }
}

/// Раскладки, реально участвующие в работе. Меньше двух — чинить нечего.
func activeLayouts(from layouts: [Layout]) -> [Layout] {
    let active = layouts.filter { Settings.shared.isLayoutActive($0) }
    return active.count >= 2 ? active : layouts
}
