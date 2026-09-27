import Foundation

enum MicrophoneChoice: String, Codable {
    case mac
    case bluetooth
}

struct RememberedChoice: Codable, Equatable {
    let microphone: MicrophoneChoice
    let deviceName: String
}

/// Stores only the user's explicit per-device choices in the app's local preferences.
struct RememberedChoices {
    private let defaults: UserDefaults
    private let storageKey = "rememberedMicrophoneChoices"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func choice(for key: String) -> RememberedChoice? {
        allChoices()[key]
    }

    func save(_ choice: RememberedChoice, for key: String) {
        var choices = allChoices()
        choices[key] = choice
        persist(choices)
    }

    func forget(_ key: String) {
        var choices = allChoices()
        choices.removeValue(forKey: key)
        persist(choices)
    }

    private func allChoices() -> [String: RememberedChoice] {
        guard let data = defaults.data(forKey: storageKey),
              let choices = try? PropertyListDecoder().decode([String: RememberedChoice].self, from: data)
        else { return [:] }
        return choices
    }

    private func persist(_ choices: [String: RememberedChoice]) {
        guard let data = try? PropertyListEncoder().encode(choices) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
