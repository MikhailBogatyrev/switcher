import Cocoa
import Carbon
import IOKit

// MARK: - Защищённый ввод
//
// Пока фокус стоит в поле пароля, система включает Secure Event Input, и тогда события
// клавиатуры не доходят ни до одного перехватчика — ни до нашего, ни до чужого. Это не
// поломка и не наша ошибка, а защита: так пароль не прочитает никакая программа.
//
// Беда в том, что снаружи это выглядит ровно как сломанное приложение: слово не чинится,
// хоткей проваливается в текст (⌥/ оставляет «÷»). Хуже того, браузеры иногда забывают
// снять защиту, уйдя в фон, — и «не работает» растягивается на часы. Поэтому состояние
// видно на иконке и названо в меню: понятно, что молчим не мы.

enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Кто держит защиту. Система числит её за приложением, а не за его вкладкой или
    /// процессом-помощником, поэтому имя получается человеческое: «Google Chrome».
    static func holderName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntrySearchCFProperty(
                root, kIOServicePlane, "IOConsoleUsers" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)),
              let sessions = property as? [[String: Any]] else { return nil }
        for session in sessions {
            guard let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid != 0 else { continue }
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "процесс \(pid)"
        }
        return nil
    }
}
