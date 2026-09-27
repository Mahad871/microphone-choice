import Foundation

struct DeviceDiagnostic {
    var name: String
    var available: Bool
    var lastConnected: Date?
    var lastDisconnected: Date?
    var status: String
}

final class ConnectionDiagnostics {
    private(set) var devices: [String: DeviceDiagnostic] = [:]
    private var events: [(Date, String)] = []

    func started(with inputs: [InputDevice]) {
        for device in inputs {
            devices[device.connectionKey] = DeviceDiagnostic(name: device.name, available: true,
                status: "Popup skipped: already connected when the app started.")
        }
        record("Monitoring started.")
    }

    func detected(_ device: InputDevice) {
        var state = devices[device.connectionKey] ??
            DeviceDiagnostic(name: device.name, available: true, status: "")
        state.name = device.name
        state.available = true
        state.lastConnected = Date()
        state.status = "Microphone detected; waiting for a choice."
        devices[device.connectionKey] = state
        record("Connected: \(device.name).")
    }

    func disconnected(_ key: String) {
        guard var state = devices[key] else { return }
        state.available = false
        state.lastDisconnected = Date()
        state.status = "Disconnected. The next connection can show a new choice."
        devices[key] = state
        record("Disconnected: \(state.name).")
    }

    func updateAvailability(_ inputs: [InputDevice]) {
        let keys = Set(inputs.map(\.connectionKey))
        for key in devices.keys { devices[key]?.available = keys.contains(key) }
    }

    func setStatus(_ status: String, for device: InputDevice) {
        if devices[device.connectionKey] == nil { detected(device) }
        devices[device.connectionKey]?.status = status
        record("\(device.name): \(status)")
    }

    func record(_ message: String) {
        events.append((Date(), message))
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    func report(currentInput: String, preferredInput: String, notificationStatus: String,
                shortcutStatus: String) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var lines = ["Microphone Choice \(version)", "Current input: \(currentInput)",
                     "Preferred input available now: \(preferredInput)",
                     "Notifications: \(notificationStatus)", "Keyboard shortcut: \(shortcutStatus)",
                     "", "Bluetooth microphones"]
        if devices.isEmpty { lines.append("No Bluetooth microphone has been detected in this session.") }
        for state in devices.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            lines += ["", state.name, "Detected now: \(state.available ? "Yes" : "No")",
                      "Last connection: \(format(state.lastConnected))",
                      "Last disconnect: \(format(state.lastDisconnected))", state.status]
        }
        lines += ["", "Recent events (this session; no device identifiers)"]
        lines += events.suffix(30).map { "\(format($0.0)): \($0.1)" }
        return lines.joined(separator: "\n")
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "Not observed in this session" }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)
    }
}
