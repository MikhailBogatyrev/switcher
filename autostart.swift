import Cocoa

// MARK: - Автозапуск при входе в систему
//
// SMAppService требует .app-бандла, а у нас голый бинарник, поэтому используем LaunchAgent.
// Права Универсального доступа выдаются конкретному исполняемому файлу, так что
// автозапуск того же самого бинарника разрешение не теряет.

enum Autostart {
    static let label = "local.switcher"

    private static var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Путь к запущенному бинарнику — его же и пропишем в автозапуск.
    private static var executablePath: String {
        ProcessInfo.processInfo.arguments.first.flatMap {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func enable() -> Bool {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--auto"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                            format: .xml, options: 0)
        else { return false }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: plistURL)) != nil else { return false }
        return launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
    }

    @discardableResult
    static func disable() -> Bool {
        _ = launchctl("bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.removeItem(at: plistURL)
        return true
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
