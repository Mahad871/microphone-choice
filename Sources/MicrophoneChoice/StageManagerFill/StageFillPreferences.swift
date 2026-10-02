import Foundation

final class StageFillPreferences {
    static let defaultReservation = 220
    static let maximumReservation = 2000
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.object(forKey: "stageFillEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stageFillEnabled") }
    }

    var rememberPerDisplay: Bool {
        get { defaults.bool(forKey: "stageFillPerDisplay") }
        set { defaults.set(newValue, forKey: "stageFillPerDisplay") }
    }

    var defaultReservation: Int {
        get {
            guard let saved = defaults.object(forKey: "stageFillDefaultReservation") as? Int else {
                return Self.defaultReservation
            }
            return Self.clamp(saved)
        }
        set { defaults.set(Self.clamp(newValue), forKey: "stageFillDefaultReservation") }
    }

    func reservation(for displayKey: String) -> Int {
        guard rememberPerDisplay,
              let saved = (defaults.dictionary(forKey: "stageFillDisplayReservations") ?? [:])[displayKey] as? Int
        else { return defaultReservation }
        return Self.clamp(saved)
    }

    func setReservation(_ width: Int, for displayKey: String?) {
        guard let displayKey, rememberPerDisplay else {
            defaultReservation = width
            return
        }
        var widths = defaults.dictionary(forKey: "stageFillDisplayReservations") ?? [:]
        widths[displayKey] = Self.clamp(width)
        defaults.set(widths, forKey: "stageFillDisplayReservations")
    }

    private static func clamp(_ width: Int) -> Int {
        min(max(0, width), maximumReservation)
    }
}
