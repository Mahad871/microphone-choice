import Foundation

func checkAppSettings() {
    let suite = "io.github.mahad871.microphonechoice.settings.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    assert(settings.preferredInputUID == nil)
    assert(settings.startAtLogin && settings.notificationsEnabled)
    assert(!settings.shortcut.enabled)
    assert(settings.theme == .system)
    settings.theme = .dark
    settings.preferredInputUID = "usb"
    settings.preferredInputName = "USB microphone"
    settings.notificationsEnabled = false
    settings.startAtLogin = false
    settings.shortcut = ShortcutConfiguration(enabled: true, control: true, option: false,
                                             shift: false, command: true, key: "K")
    let reloaded = AppSettings(defaults: defaults)
    assert(reloaded.preferredInputUID == "usb")
    assert(reloaded.theme == .dark)
    reloaded.theme = .system
    assert(AppSettings(defaults: defaults).theme == .system)
    defaults.set("invalid", forKey: "appearance")
    assert(settings.theme == .system)
    assert(!reloaded.notificationsEnabled && !reloaded.startAtLogin)
    assert(reloaded.shortcut.displayName == "⌃⌘K")
    assert(reloaded.shortcut.validationError == nil)
    assert(ShortcutConfiguration(enabled: true, control: false, option: true,
        shift: true, command: false, key: "K").validationError != nil)

    let builtIn = InputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "Built-in", isBluetooth: false)
    let usb = InputDevice(id: 2, uid: "usb", name: "USB", isBluetooth: false)
    let headset = InputDevice(id: 3, uid: "headset", name: "Headset", isBluetooth: true)
    assert(preferredMicrophone(in: [headset, builtIn, usb], configuredUID: "usb") == usb)
    assert(preferredMicrophone(in: [headset, builtIn], configuredUID: "usb") == builtIn)
    assert(preferredMicrophone(in: [headset, usb], configuredUID: nil) == usb)
    assert(preferredMicrophone(in: [headset], configuredUID: "headset") == nil)

    let diagnostic = ConnectionDiagnostics()
    diagnostic.started(with: [])
    diagnostic.detected(headset)
    diagnostic.setStatus("Popup skipped: applied saved choice.", for: headset)
    diagnostic.disconnected(headset.connectionKey)
    let report = diagnostic.report(currentInput: "USB", preferredInput: "USB",
                                   notificationStatus: "Off", shortcutStatus: "Off")
    assert(report.contains("Detected now: No"))
    assert(report.contains("Popup skipped: applied saved choice."))
    assert(!report.contains("Device UID"))
    let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: lockDirectory) }
    var firstInstance: SingleInstance? = SingleInstance(directory: lockDirectory)
    assert(firstInstance!.acquired)
    let duplicate = SingleInstance(directory: lockDirectory)
    assert(!duplicate.acquired)
    firstInstance = nil
    let replacement = SingleInstance(directory: lockDirectory)
    assert(replacement.acquired)
    print("Settings, fallback selection, and diagnostics passed")
}
