import AppKit
import CoreAudio
import Darwin
import Foundation

private let audioSystem = AudioObjectID(kAudioObjectSystemObject)

func log(_ message: String) {
    if let data = "\(Date()): \(message)\n".data(using: .utf8) { FileHandle.standardError.write(data) }
}

private struct PromptSelection {
    let microphone: MicrophoneChoice
    let remember: Bool
}

private func askAbout(name: String, device: InputDevice?, preferred: InputDevice?,
                      saved: RememberedChoice? = nil, preview: Bool = false,
                      allowInputChanges: Bool = true) -> PromptSelection? {
    if allowInputChanges, !preview, saved == nil, device != nil, let preferred {
        if !selectInput(preferred.id) { log("Could not select \(preferred.name) before the prompt") }
    }
    let promptScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let alert = NSAlert()
    if let iconURL = Bundle.main.url(forResource: "MicChoice", withExtension: "png"),
       let icon = NSImage(contentsOf: iconURL) { alert.icon = icon }
    if preview {
        alert.messageText = "Test microphone choice"
        alert.informativeText = "This is a preview for \(name). Your microphone and saved choices will not change."
    } else if let saved {
        alert.messageText = "Change microphone choice for \(name)"
        let selectedName = saved.microphone == .preferred ? "Preferred microphone" : "Bluetooth microphone"
        alert.informativeText = "Saved choice: \(selectedName). Uncheck the box to ask again next time."
        if device == nil { alert.informativeText += " Changes will apply when this device reconnects." }
    } else {
        alert.messageText = "Use \(name)’s microphone?"
        alert.informativeText = "Using a separate microphone keeps Bluetooth headphone playback at higher quality."
    }
    if let preferred, preferred.uid != "BuiltInMicrophoneDevice" {
        alert.informativeText += "\nPreferred microphone: \(preferred.name)."
    } else if preferred == nil && !preview {
        alert.informativeText += "\nNo non-Bluetooth microphone is currently available."
    }
    let rememberCheckbox = NSButton(checkboxWithTitle: "Remember my choice for this device",
                                    target: nil, action: nil)
    rememberCheckbox.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
    rememberCheckbox.state = saved == nil ? .off : .on
    rememberCheckbox.isEnabled = !preview
    alert.accessoryView = rememberCheckbox
    let preferredTitle = preferred?.uid == "BuiltInMicrophoneDevice" ? "Use Mac microphone" : "Use preferred microphone"
    let primaryButton = alert.addButton(withTitle: preferredTitle)
    primaryButton.isEnabled = preferred != nil || device == nil || preview
    let bluetoothButton = alert.addButton(withTitle: "Use Bluetooth microphone")
    if !primaryButton.isEnabled { bluetoothButton.keyEquivalent = "\r" }
    let cancel = alert.addButton(withTitle: "Cancel")
    cancel.keyEquivalent = "\u{1b}"
    alert.alertStyle = .informational
    alert.window.title = "Microphone Choice"
    alert.window.level = .floating
    alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    alert.layout()
    let accentBackground = NSView()
    accentBackground.wantsLayer = true
    accentBackground.layer?.backgroundColor = NSColor(srgbRed: 214 / 255, green: 31 / 255,
                                                       blue: 73 / 255, alpha: 1).cgColor
    accentBackground.layer?.cornerRadius = 11
    func centerPrompt() {
        if let screen = promptScreen ?? NSScreen.main {
            let bounds = screen.visibleFrame
            let size = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(x: bounds.midX - size.width / 2,
                                                y: bounds.midY - size.height / 2))
        }
    }
    if #available(macOS 14.0, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    alert.window.makeKeyAndOrderFront(nil)
    centerPrompt()
    let positionTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
        if primaryButton.isEnabled {
            primaryButton.isBordered = false
            primaryButton.contentTintColor = .white
        }
        alert.layout()
        if primaryButton.isEnabled {
            primaryButton.frame = primaryButton.frame.insetBy(dx: 0, dy: -3)
            accentBackground.frame = primaryButton.frame
            primaryButton.superview?.addSubview(accentBackground, positioned: .below, relativeTo: primaryButton)
        }
        centerPrompt()
    }
    RunLoop.main.add(positionTimer, forMode: .common)
    log("Showing \(preview ? "test " : "")microphone choice for \(name)")
    let timeout = Timer(timeInterval: preview ? 8 : 60, repeats: false) { _ in NSApp.abortModal() }
    RunLoop.main.add(timeout, forMode: .common)
    let answer = alert.runModal()
    positionTimer.invalidate()
    timeout.invalidate()
    alert.window.orderOut(nil)
    let microphone: MicrophoneChoice
    switch answer {
    case .alertFirstButtonReturn: microphone = .preferred
    case .alertSecondButtonReturn: microphone = .bluetooth
    default: return nil
    }
    return PromptSelection(microphone: microphone, remember: rememberCheckbox.state == .on)
}

final class MicrophoneMonitor {
    let settings: AppSettings
    let remembered: RememberedChoices
    let diagnostics = ConnectionDiagnostics()
    let notifications: ChoiceNotifications
    let preview: Bool
    var onUpdate: (() -> Void)?
    private(set) var undoableForget: (key: String, choice: RememberedChoice)?
    private var connections = ConnectionTracker(initialInputKeys: [], connectedKeys: [])
    private let bluetooth = BluetoothConnectionObserver()
    private var pendingUIDs: [String] = []
    private var pendingChanges: [String] = []
    private var pendingPreview = false
    private var isPresenting = false
    private var timer: Timer?
    private var lastCurrentInput: InputDevice?

    init(settings: AppSettings, remembered: RememberedChoices,
         notifications: ChoiceNotifications, preview: Bool = false) {
        self.settings = settings
        self.remembered = remembered
        self.notifications = notifications
        self.preview = preview
    }

    var preferredInput: InputDevice? { preferredMicrophone(settings.preferredInputUID) }
    var connectedBluetoothInputs: [InputDevice] {
        let inputs = bluetoothInputs()
        if preview { return inputs }
        let available = bluetooth.availableKeys(from: Set(inputs.map(\.connectionKey)))
        return inputs.filter { available.contains($0.connectionKey) }
    }

    func start() {
        let current = bluetoothInputs()
        diagnostics.started(with: current)
        lastCurrentInput = currentInputDevice()
        connections = ConnectionTracker(initialInputKeys: Set(current.map(\.connectionKey)),
                                         connectedKeys: bluetoothConnectionKeys())
        if !preview {
            bluetooth.onDisconnect = { [weak self] key in
                guard let self else { return }
                self.connections.physicallyDisconnected(key)
                self.pendingUIDs.removeAll { $0 == key }
                self.diagnostics.disconnected(key)
                if self.lastCurrentInput?.isBluetooth == true && self.lastCurrentInput?.connectionKey == key {
                    _ = self.apply(.preferred, device: nil)
                }
                self.onUpdate?()
                log("Bluetooth disconnected: \(key)")
            }
            bluetooth.onConnect = { [weak self] in self?.scan() }
            bluetooth.start(watching: bluetoothConnectionKeys())
            if let selected = lastCurrentInput, selected.isBluetooth,
               remembered.choice(for: selected.connectionKey)?.microphone != .bluetooth {
                _ = apply(.preferred, device: nil)
            }
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var address = propertyAddress(selector)
                let status = AudioObjectAddPropertyListenerBlock(audioSystem, &address, .main) { [weak self] _, _ in
                    self?.scan()
                }
                if status != noErr { diagnostics.record("Core Audio listener failed (\(status)). Polling remains active.") }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.scan() }
        log("Watching Bluetooth microphones")
    }

    func scan() {
        if !preview, let previous = lastCurrentInput, !previous.isBluetooth,
           !inputDevices().contains(where: { $0.uid == previous.uid }) {
            if apply(.preferred, device: nil) {
                diagnostics.record("The selected microphone disconnected; switched to the available preferred input.")
            }
        }
        let current = connectedBluetoothInputs
        diagnostics.updateAvailability(current)
        if !preview {
            let currentKeys = Set(current.map(\.connectionKey))
            let connectedKeys = bluetooth.availableKeys(from: bluetoothConnectionKeys())
            for key in connections.newlyConnected(currentKeys, connectedKeys: connectedKeys)
                where !pendingUIDs.contains(key) {
                pendingUIDs.append(key)
                if let device = current.first(where: { $0.connectionKey == key }) { diagnostics.detected(device) }
                log("Queued microphone choice for \(key)")
            }
        }
        lastCurrentInput = currentInputDevice()
        onUpdate?()
        presentNextIfIdle()
    }

    func switchInput(to uid: String) {
        guard let device = inputDevices().first(where: { $0.uid == uid }) else {
            diagnostics.record("Requested microphone is no longer available.")
            onUpdate?()
            return
        }
        if preview || selectInput(device.id) {
            diagnostics.record("Manually selected \(device.displayName). Saved choices were left unchanged.")
            lastCurrentInput = device
        } else { diagnostics.record("Could not switch to \(device.name).") }
        onUpdate?()
    }

    func usePreferredInput() { _ = apply(.preferred, device: nil); onUpdate?() }

    @discardableResult
    private func apply(_ microphone: MicrophoneChoice, device: InputDevice?) -> Bool {
        let selected: InputDevice?
        switch microphone {
        case .preferred: selected = preferredInput
        case .bluetooth:
            selected = connectedBluetoothInputs.first { $0.connectionKey == device?.connectionKey }
        }
        guard let selected else {
            diagnostics.record("The requested microphone is unavailable.")
            return false
        }
        if !preview && !selectInput(selected.id) {
            diagnostics.record("Could not select \(selected.name).")
            return false
        }
        lastCurrentInput = selected
        log("Selected \(selected.displayName)")
        return true
    }

    func requestChoice(for key: String) {
        guard !pendingChanges.contains(key),
              remembered.choice(for: key) != nil || connectedBluetoothInputs.contains(where: { $0.connectionKey == key })
        else { return }
        pendingUIDs.removeAll { $0 == key }
        pendingChanges.append(key)
        presentNextIfIdle()
    }

    func requestDiagnosticPrompt() {
        if let device = connectedBluetoothInputs.first { requestChoice(for: device.connectionKey) }
        else { testPopup() }
    }

    func testPopup() { pendingPreview = true; presentNextIfIdle() }

    func changeSavedChoice(for key: String, to microphone: MicrophoneChoice) {
        guard let saved = remembered.choice(for: key) else { return }
        remembered.save(RememberedChoice(microphone: microphone, deviceName: saved.deviceName), for: key)
        if let device = connectedBluetoothInputs.first(where: { $0.connectionKey == key }) {
            _ = apply(microphone, device: device)
            diagnostics.setStatus("Saved choice changed to \(microphone == .preferred ? "preferred" : "Bluetooth") microphone.", for: device)
        }
        onUpdate?()
    }

    func forgetChoice(for key: String) {
        guard let saved = remembered.choice(for: key) else { return }
        undoableForget = (key, saved)
        remembered.forget(key)
        diagnostics.record("Forgot saved choice for \(saved.deviceName). A future connection will ask again.")
        onUpdate?()
    }

    func undoForget() {
        guard let last = undoableForget else { return }
        remembered.save(last.choice, for: last.key)
        diagnostics.record("Restored saved choice for \(last.choice.deviceName).")
        undoableForget = nil
        onUpdate?()
    }

    func preferenceChanged(_ message: String) { diagnostics.record(message); onUpdate?() }

    func diagnosticReport(shortcutStatus: String) -> String {
        diagnostics.report(currentInput: currentInputDevice()?.displayName ?? "Unavailable",
            preferredInput: preferredInput?.displayName ?? "Unavailable",
            notificationStatus: settings.notificationsEnabled ? notifications.permissionStatus : "Off in app settings",
            shortcutStatus: shortcutStatus)
    }

    private func saveSelection(_ selection: PromptSelection, for key: String,
                               name: String, device: InputDevice?) {
        if device != nil { _ = apply(selection.microphone, device: device) }
        if selection.remember {
            remembered.save(RememberedChoice(microphone: selection.microphone, deviceName: name), for: key)
            notifications.requestPermission()
            diagnostics.record("Remembered \(selection.microphone == .preferred ? "preferred" : "Bluetooth") microphone for \(name).")
        } else if remembered.choice(for: key) != nil { forgetChoice(for: key) }
        onUpdate?()
    }

    private func presentNextIfIdle() {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false; onUpdate?() }
        while pendingPreview || !pendingChanges.isEmpty || !pendingUIDs.isEmpty {
            if pendingPreview {
                pendingPreview = false
                let device = connectedBluetoothInputs.first
                _ = askAbout(name: device?.name ?? "Example Bluetooth device", device: device,
                             preferred: preferredInput, preview: true)
                diagnostics.record("Test popup shown. No audio or saved-choice changes were made.")
                continue
            }
            if !pendingChanges.isEmpty {
                let key = pendingChanges.removeFirst()
                let saved = remembered.choice(for: key)
                let device = connectedBluetoothInputs.first(where: { $0.connectionKey == key })
                guard device != nil || saved != nil else { continue }
                connections.beginPrompt(for: key)
                if let selection = askAbout(name: device?.name ?? saved!.deviceName, device: device,
                                            preferred: preferredInput, saved: saved, allowInputChanges: !preview) {
                    saveSelection(selection, for: key, name: device?.name ?? saved!.deviceName, device: device)
                }
                connections.endPrompt(for: key)
                continue
            }
            let key = pendingUIDs.removeFirst()
            guard let device = connectedBluetoothInputs.first(where: { $0.connectionKey == key }) else { continue }
            connections.beginPrompt(for: key)
            if let saved = remembered.choice(for: key), apply(saved.microphone, device: device) {
                let latest = RememberedChoice(microphone: saved.microphone, deviceName: device.name)
                remembered.save(latest, for: key)
                notifications.showAppliedChoice(latest, for: key,
                    preferredName: preferredInput?.displayName ?? "preferred microphone")
                diagnostics.setStatus("Popup skipped: applied saved \(saved.microphone == .preferred ? "preferred" : "Bluetooth") microphone choice.", for: device)
            } else {
                diagnostics.setStatus("Showing the microphone choice popup.", for: device)
                if let selection = askAbout(name: device.name, device: device, preferred: preferredInput,
                                            saved: remembered.choice(for: key), allowInputChanges: !preview) {
                    saveSelection(selection, for: key, name: device.name, device: device)
                    diagnostics.setStatus("Choice handled. Popup skipped until the next connection.", for: device)
                } else {
                    diagnostics.setStatus("Popup dismissed or timed out; kept the current input. No saved choice changed.", for: device)
                }
            }
            connections.endPrompt(for: key)
        }
    }
}

if CommandLine.arguments.contains("--probe") {
    for device in bluetoothInputs() { print("\(device.name)\t\(device.uid)") }
} else if CommandLine.arguments.contains("--probe-inputs") {
    for device in inputDevices() { print("\(device.displayName)\t\(device.isBluetooth ? "Bluetooth" : "Local")") }
} else {
    let preview = CommandLine.arguments.contains("--preview")
    let testPrompt = CommandLine.arguments.contains("--test-prompt")
    let instance = preview || testPrompt ? nil : SingleInstance()
    if let instance, !instance.acquired {
        DistributedNotificationCenter.default().postNotificationName(showSettingsNotification, object: nil)
        exit(0)
    }
    let suiteName = preview ? "io.github.mahad871.microphonechoice.preview.\(UUID().uuidString)" : nil
    let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    let settings = AppSettings(defaults: defaults)
    let remembered = RememberedChoices(defaults: defaults)
    if preview {
        remembered.save(RememberedChoice(microphone: .preferred, deviceName: "Soundcore Life Q30"), for: "preview-a")
        remembered.save(RememberedChoice(microphone: .bluetooth,
            deviceName: "A very long Bluetooth conference headset name for layout verification"), for: "preview-b")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(preview ? .regular : .accessory)
    if preview && CommandLine.arguments.contains("--preview-light") {
        settings.theme = .light
    } else if preview && CommandLine.arguments.contains("--preview-dark") {
        settings.theme = .dark
    }
    app.appearance = settings.theme.appearance
    let notifications = ChoiceNotifications()
    notifications.enabled = settings.notificationsEnabled
    if !testPrompt && !preview { notifications.start() }
    app.finishLaunching()
    if testPrompt {
        let device = bluetoothInputs().first
        _ = askAbout(name: device?.name ?? "Example Bluetooth device", device: device,
                     preferred: preferredMicrophone(settings.preferredInputUID), preview: true)
    } else {
        let login = LoginController(settings: settings,
            homebrewManaged: CommandLine.arguments.contains("--no-login-item") ||
                LoginController.existingHomebrewServiceMatchesApp, preview: preview)
        login.configureInitialLogin()
        let shortcut = GlobalShortcut()
        let monitor = MicrophoneMonitor(settings: settings, remembered: remembered,
                                       notifications: notifications, preview: preview)
        let stageFill = StageManagerFeature(preferences: StageFillPreferences(defaults: defaults),
                                            preview: preview)
        let desktop = DesktopController(monitor: monitor, login: login, shortcut: shortcut,
                                        stageFill: stageFill)
        app.delegate = desktop
        desktop.onTermination = { if let suiteName { defaults.removePersistentDomain(forName: suiteName) } }
        notifications.onChangeChoice = { [weak monitor] key in monitor?.requestChoice(for: key) }
        notifications.onStatusChanged = { [weak desktop] in desktop?.refresh() }
        monitor.onUpdate = { [weak desktop] in desktop?.refresh() }
        shortcut.onInvoke = { [weak desktop, weak monitor] in
            monitor?.diagnostics.record("Keyboard shortcut invoked.")
            desktop?.showChoiceOrSettings()
        }
        if let error = shortcut.configure(settings.shortcut) { monitor.diagnostics.record(error) }
        monitor.start()
        desktop.start()
        _ = DistributedNotificationCenter.default().addObserver(forName: showSettingsNotification,
            object: nil, queue: .main) { [weak desktop] _ in desktop?.showSettings(tab: 0) }
        Darwin.signal(SIGUSR1, SIG_IGN)
        let diagnosticSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        diagnosticSignal.setEventHandler { monitor.requestDiagnosticPrompt() }
        diagnosticSignal.resume()
        if preview { desktop.showSettings(tab: 0) }
        withExtendedLifetime((instance, desktop, diagnosticSignal)) { app.run() }
    }
}
