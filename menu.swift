import Cocoa

// MARK: - Иконка и меню в строке меню

/// Короткая история для самого меню; полный журнал живёт в ConversionLog.
private var history: [(from: String, to: String)] = []

func recordFix(from typed: String, to fixed: String) {
    // В меню строка целиком не влезет: при ручной починке это может быть вся строка.
    func short(_ text: String) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 28 ? "…" + flat.suffix(27) : flat
    }
    history.insert((short(typed), short(fixed)), at: 0)
    if history.count > 8 { history.removeLast() }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let layouts: [Layout]

    init(layouts: [Layout]) {
        self.layouts = layouts
        super.init()

        // Узкий фиксированный размер — не косметика: на экранах с вырезом строка меню
        // быстро кончается, и лишние пиксели утаскивают иконку под чёлку, где она
        // не видна и не нажимается.
        item.length = 24
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(systemSymbolName: "character.cursor.ibeam",
                                   accessibilityDescription: "switcher")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            if button.image == nil { button.title = "⇄" }
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuild(menu)

        // Диагностика запуска: если иконки не видно, отсюда понятно, кто виноват —
        // приложение её не создало или система не нашла места в строке меню.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.writeStartupReport() }
    }

    private func writeStartupReport() {
        let screen = NSScreen.main?.frame ?? .zero
        let visibleTop = NSScreen.main?.visibleFrame.maxY ?? 0
        var lines = [
            "pid            : \(ProcessInfo.processInfo.processIdentifier)",
            "исполняемый    : \(Bundle.main.bundlePath)",
            "bundleID       : \(Bundle.main.bundleIdentifier ?? "нет")",
            "доступ выдан   : \(AXIsProcessTrusted())",
            "перехват готов : \(inputCaptureReady)",
            "кнопка создана : \(item.button != nil)",
            "картинка есть  : \(item.button?.image != nil)",
            "isVisible      : \(item.isVisible)",
            "ширина кнопки  : \(item.button?.frame.width ?? -1)",
            "экран          : \(Int(screen.width))x\(Int(screen.height)), полоса меню \(Int(screen.height - visibleTop)) px",
        ]
        if let window = item.button?.window {
            lines.append("окно кнопки    : frame=\(window.frame) onScreen=\(window.isOnActiveSpace)")
        } else {
            lines.append("окно кнопки    : НЕТ — элемент не размещён в строке меню")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dataDirectory().appendingPathComponent("startup.log"),
                        atomically: true, encoding: .utf8)
    }

    // Пересобираем при каждом открытии: и настройки, и журнал живые.
    func menuWillOpen(_ menu: NSMenu) { rebuild(menu) }

    /// Позвать, когда состояние поменялось снаружи (например, выдали права).
    func refresh() {
        if let menu = item.menu { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        let settings = Settings.shared
        menu.removeAllItems()

        // Без прав программа видна, но бессильна — говорим об этом первым же пунктом.
        if !inputCaptureReady {
            menu.addItem(info("⚠︎ Нет доступа к Универсальному доступу"))
            menu.addItem(plain("Открыть настройки и выдать доступ…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        menu.addItem(action("Чинить автоматически", #selector(toggleAuto),
                            checked: settings.autoEnabled))
        menu.addItem(info("Перебить вручную: \(settings.hotkey.title)"))
        menu.addItem(.separator())

        // --- Поведение ---
        let manual = NSMenu()
        for mode in ManualMode.allCases {
            manual.addItem(action(mode.title, #selector(setManualMode(_:)),
                                  checked: settings.manualMode == mode, tag: mode.rawValue))
        }
        menu.addItem(submenu("Без выделения чинить…", manual))

        let switching = NSMenu()
        for rule in LayoutSwitchRule.allCases {
            switching.addItem(action(rule.title, #selector(setSwitchRule(_:)),
                                     checked: settings.layoutSwitchRule == rule,
                                     tag: rule.rawValue))
        }
        menu.addItem(submenu("Менять раскладку…", switching))

        let shortWords = NSMenu()
        for rule in ShortWordRule.allCases {
            shortWords.addItem(action(rule.title, #selector(setShortWordRule(_:)),
                                      checked: settings.shortWordRule == rule,
                                      tag: rule.rawValue))
        }
        menu.addItem(submenu("Чинить короткие слова…", shortWords))

        let hotkeys = NSMenu()
        for (index, choice) in HotkeyChoice.all.enumerated() {
            hotkeys.addItem(action(choice.title, #selector(setHotkey(_:)),
                                   checked: settings.hotkeyIndex == index, tag: index))
        }
        hotkeys.addItem(.separator())
        hotkeys.addItem(action("Плюс двойной Shift", #selector(toggleDoubleShift),
                               checked: settings.useDoubleShift))
        menu.addItem(submenu("Сочетание клавиш", hotkeys))

        let layoutMenu = NSMenu()
        for (index, layout) in layouts.enumerated() {
            layoutMenu.addItem(action("\(layout.name) — \(layout.languages.first ?? "?")",
                                      #selector(toggleLayout(_:)),
                                      checked: settings.isLayoutActive(layout), tag: index))
        }
        menu.addItem(submenu("Раскладки", layoutMenu))
        menu.addItem(.separator())

        // --- Обратная связь ---
        menu.addItem(action("Звук при починке", #selector(toggleSound),
                            checked: settings.playSound))
        menu.addItem(action("Уведомления", #selector(toggleNotifications),
                            checked: settings.showNotifications))
        menu.addItem(action("Запускать при входе в систему", #selector(toggleAutostart),
                            checked: Autostart.isEnabled))
        menu.addItem(.separator())

        // --- Журнал ---
        let log = ConversionLog.shared
        if log.entries.isEmpty {
            menu.addItem(info("Починок пока не было"))
        } else {
            let wrong = log.wrongCount
            menu.addItem(info("Починок: \(log.entries.count)"
                              + (wrong > 0 ? ", неверных: \(wrong)" : "")))
            for entry in log.entries.prefix(8) {
                let rating = NSMenu()
                rating.addItem(action("Сработало верно", #selector(rateCorrect(_:)),
                                      checked: entry.correct == true, tag: entry.id))
                rating.addItem(action("Сработало неверно", #selector(rateWrong(_:)),
                                      checked: entry.correct == false, tag: entry.id))
                menu.addItem(submenu("   " + entry.short, rating))
            }
            menu.addItem(plain("Сохранить журнал в файл…", #selector(exportLog)))
            menu.addItem(plain("Очистить журнал", #selector(clearLog)))
        }
        menu.addItem(.separator())

        let learned = LearnedWords.shared.count
        if learned > 0 {
            menu.addItem(info("Выучено слов: \(learned)"))
            menu.addItem(plain("Забыть выученные слова", #selector(forgetLearned)))
            menu.addItem(.separator())
        }

        menu.addItem(plain("Настройки Универсального доступа…", #selector(openAccessibility)))
        let quit = plain("Выйти", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: Сборка пунктов

    private func info(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func plain(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func action(_ title: String, _ selector: Selector,
                        checked: Bool, tag: Int = 0) -> NSMenuItem {
        let entry = plain(title, selector)
        entry.state = checked ? .on : .off
        entry.tag = tag
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    // MARK: Действия

    @objc private func toggleAuto() { setAutoMode(enabled: !isAutoModeEnabled) }

    @objc private func setManualMode(_ sender: NSMenuItem) {
        Settings.shared.manualMode = ManualMode(rawValue: sender.tag) ?? .greedy
    }

    @objc private func setSwitchRule(_ sender: NSMenuItem) {
        Settings.shared.layoutSwitchRule =
            LayoutSwitchRule(rawValue: sender.tag) ?? .ifAnythingChanged
    }

    @objc private func setShortWordRule(_ sender: NSMenuItem) {
        Settings.shared.shortWordRule = ShortWordRule(rawValue: sender.tag) ?? .twoLetters
    }

    @objc private func setHotkey(_ sender: NSMenuItem) {
        Settings.shared.hotkeyIndex = sender.tag
        registerHotkey()
    }

    @objc private func toggleDoubleShift() { Settings.shared.useDoubleShift.toggle() }

    @objc private func toggleLayout(_ sender: NSMenuItem) {
        guard layouts.indices.contains(sender.tag) else { return }
        Settings.shared.toggleLayout(layouts[sender.tag])
    }

    @objc private func toggleSound() { Settings.shared.playSound.toggle() }

    @objc private func toggleNotifications() {
        Settings.shared.showNotifications.toggle()
        prepareNotifications()
    }

    @objc private func toggleAutostart() {
        if Autostart.isEnabled {
            Autostart.disable()
        } else if !Autostart.enable() {
            warn("Не удалось включить автозапуск", "launchctl отказался загрузить агент.")
        }
    }

    @objc private func rateCorrect(_ sender: NSMenuItem) {
        ConversionLog.shared.rate(id: sender.tag, correct: true)
    }

    @objc private func rateWrong(_ sender: NSMenuItem) {
        ConversionLog.shared.rate(id: sender.tag, correct: false)
    }

    @objc private func exportLog() {
        guard let data = ConversionLog.shared.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "switcher-log.json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            warn("Не удалось сохранить журнал", error.localizedDescription)
        }
    }

    @objc private func clearLog() {
        ConversionLog.shared.clear()
        history.removeAll()
    }

    @objc private func forgetLearned() {
        LearnedWords.shared.removeAll()
    }

    @objc private func openAccessibility() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func warn(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
