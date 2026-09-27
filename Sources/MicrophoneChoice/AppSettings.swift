import Foundation

enum AppTheme: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct ShortcutConfiguration: Codable, Equatable {
    var enabled = false
    var control = true
    var option = true
    var shift = false
    var command = true
    var key = "M"

    var displayName: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") +
            (command ? "⌘" : "") + key
    }

    var validationError: String? {
        guard !enabled || control || command else {
            return "Include Control or Command so the shortcut works reliably across macOS versions."
        }
        guard Self.keyCodes[key] != nil else { return "Choose a letter from A to Z." }
        return nil
    }

    static let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32,
        "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46
    ]
}

final class AppSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var theme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    var preferredInputUID: String? {
        get { defaults.string(forKey: "preferredInputUID") }
        set { defaults.set(newValue, forKey: "preferredInputUID") }
    }
    var preferredInputName: String? {
        get { defaults.string(forKey: "preferredInputName") }
        set { defaults.set(newValue, forKey: "preferredInputName") }
    }
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: "savedChoiceNotificationsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "savedChoiceNotificationsEnabled") }
    }
    var startAtLogin: Bool {
        get { defaults.object(forKey: "startAtLogin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "startAtLogin") }
    }
    var shortcut: ShortcutConfiguration {
        get {
            guard let data = defaults.data(forKey: "globalShortcut"),
                  let value = try? PropertyListDecoder().decode(ShortcutConfiguration.self, from: data)
            else { return ShortcutConfiguration() }
            return value
        }
        set {
            if let data = try? PropertyListEncoder().encode(newValue) {
                defaults.set(data, forKey: "globalShortcut")
            }
        }
    }
}
