import AppKit
import CoreAudio
import Darwin
import Foundation
import ServiceManagement

private let audioSystem = AudioObjectID(kAudioObjectSystemObject)
private let promptTimeout: TimeInterval = CommandLine.arguments.contains("--test-prompt") ? 8 : 60

private struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var connectionKey: String { bluetoothConnectionKey(uid) }
}

private func propertyAddress(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func deviceIDs() -> [AudioDeviceID] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(audioSystem, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(audioSystem, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func uintProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = propertyAddress(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
          let result = value else { return nil }
    return result.takeUnretainedValue() as String
}

private func hasInputStream(_ id: AudioDeviceID) -> Bool {
    var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size >= MemoryLayout<AudioStreamID>.size
}

private func bluetoothInputs() -> [InputDevice] {
    deviceIDs().compactMap { id in
        guard let transport = uintProperty(id, kAudioDevicePropertyTransportType),
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              hasInputStream(id),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

private func bluetoothConnectionKeys() -> Set<String> {
    Set(deviceIDs().compactMap { id in
        guard let transport = uintProperty(id, kAudioDevicePropertyTransportType),
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return bluetoothConnectionKey(uid)
    })
}

private func builtInMicrophone() -> AudioDeviceID? {
    deviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == "BuiltInMicrophoneDevice" }
}

@discardableResult
private func selectInput(_ id: AudioDeviceID) -> Bool {
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    var selected = id
    let status = AudioObjectSetPropertyData(audioSystem, &address, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &selected)
    return status == noErr
}

private func log(_ message: String) {
    let line = "\(Date()): \(message)\n"
    if let data = line.data(using: .utf8) { FileHandle.standardError.write(data) }
}

private func registerLoginItemIfNeeded() {
    let service = SMAppService.mainApp
    guard service.status == .notRegistered else { return }
    do {
        try service.register()
        log("Registered to start at login")
    } catch {
        log("Could not register login item: \(error.localizedDescription)")
    }
}

private struct PromptSelection {
    let microphone: MicrophoneChoice
    let remember: Bool
}

private func askAbout(name: String, device: InputDevice?, saved: RememberedChoice? = nil) -> PromptSelection? {
    if saved == nil, device != nil, let macMic = builtInMicrophone() {
        guard selectInput(macMic) else {
            log("Could not select the built in microphone")
            return nil
        }
    }

    let promptScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let alert = NSAlert()
    if let iconURL = Bundle.main.url(forResource: "MicChoice", withExtension: "png"),
       let icon = NSImage(contentsOf: iconURL) {
        alert.icon = icon
    }
    if let saved {
        alert.messageText = "Change microphone choice for \(name)"
        let selectedName = saved.microphone == .mac ? "Mac microphone" : "Bluetooth microphone"
        alert.informativeText = "Saved choice: \(selectedName). Uncheck the box to ask again next time."
        if device == nil { alert.informativeText += " Changes will apply when this device reconnects." }
    } else {
        alert.messageText = "Use \(name)’s microphone?"
        alert.informativeText = "The Mac microphone keeps Bluetooth headphone playback at higher quality."
    }
    let rememberCheckbox = NSButton(checkboxWithTitle: "Remember my choice for this device",
                                    target: nil, action: nil)
    rememberCheckbox.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
    rememberCheckbox.state = saved == nil ? .off : .on
    alert.accessoryView = rememberCheckbox
    let macButton = alert.addButton(withTitle: "Use Mac microphone")
    alert.addButton(withTitle: "Use Bluetooth microphone")
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
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
    alert.window.makeKeyAndOrderFront(nil)
    centerPrompt()
    let positionTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
        macButton.isBordered = false
        macButton.contentTintColor = .white
        alert.layout()
        macButton.frame = macButton.frame.insetBy(dx: 0, dy: -3)
        accentBackground.frame = macButton.frame
        macButton.superview?.addSubview(accentBackground, positioned: .below, relativeTo: macButton)
        centerPrompt()
    }
    RunLoop.main.add(positionTimer, forMode: .common)
    log("Showing microphone choice for \(name)")

    let timeout = Timer(timeInterval: promptTimeout, repeats: false) { _ in
        NSApp.abortModal()
    }
    RunLoop.main.add(timeout, forMode: .common)
    let answer = alert.runModal()
    positionTimer.invalidate()
    timeout.invalidate()
    alert.window.orderOut(nil)

    let microphone: MicrophoneChoice
    switch answer {
    case .alertFirstButtonReturn: microphone = .mac
    case .alertSecondButtonReturn: microphone = .bluetooth
    default: return nil
    }
    return PromptSelection(microphone: microphone, remember: rememberCheckbox.state == .on)
}

@discardableResult
private func applyChoice(_ microphone: MicrophoneChoice, device: InputDevice?) -> Bool {
    switch microphone {
    case .mac:
        guard let macMic = builtInMicrophone(), selectInput(macMic) else {
            log("Could not select the built in microphone")
            return false
        }
        log("Selected Mac microphone")
        return true
    case .bluetooth:
        guard let device, bluetoothInputs().contains(where: { $0.uid == device.uid }),
              selectInput(device.id) else {
            log("Bluetooth microphone became unavailable")
            return false
        }
        log("Selected \(device.name) microphone")
        return true
    }
}

private final class MicrophoneMonitor {
    private var connections = ConnectionTracker(initialInputKeys: [], connectedKeys: [])
    private let bluetooth = BluetoothConnectionObserver()
    private let remembered = RememberedChoices()
    private let notifications: ChoiceNotifications
    private var pendingUIDs: [String] = []
    private var pendingChanges: [String] = []
    private var isPresenting = false
    private var timer: Timer?

    init(notifications: ChoiceNotifications) {
        self.notifications = notifications
    }

    func start() {
        let current = bluetoothInputs()
        let connectedKeys = bluetoothConnectionKeys()
        connections = ConnectionTracker(initialInputKeys: Set(current.map(\.connectionKey)),
                                        connectedKeys: connectedKeys)
        bluetooth.onDisconnect = { [weak self] key in
            guard let self else { return }
            self.connections.physicallyDisconnected(key)
            self.pendingUIDs.removeAll { $0 == key }
            log("Bluetooth disconnected: \(key)")
        }
        bluetooth.onConnect = { [weak self] in self?.scan() }
        bluetooth.start(watching: connectedKeys)
        if let selected = uintProperty(audioSystem, kAudioHardwarePropertyDefaultInputDevice),
           let selectedDevice = current.first(where: { $0.id == selected }),
           remembered.choice(for: selectedDevice.connectionKey)?.microphone != .bluetooth,
           let macMic = builtInMicrophone() {
            _ = selectInput(macMic)
            log("Restored Mac microphone at startup")
        }

        var address = propertyAddress(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(audioSystem, &address, DispatchQueue.main) { [weak self] _, _ in
            self?.scan()
        }
        if status != noErr {
            log("Core Audio listener failed with status \(status)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.scan()
        }
        log("Watching Bluetooth microphones")
    }

    private func scan() {
        let current = bluetoothInputs()
        let currentKeys = bluetooth.availableKeys(from: Set(current.map(\.connectionKey)))
        let connectedKeys = bluetooth.availableKeys(from: bluetoothConnectionKeys())
        for key in connections.newlyConnected(currentKeys, connectedKeys: connectedKeys)
            where !pendingUIDs.contains(key) {
            pendingUIDs.append(key)
            log("Queued microphone choice for \(key)")
        }
        presentNextIfIdle()
    }

    func requestDiagnosticPrompt() {
        guard !isPresenting, let key = bluetoothInputs().first?.connectionKey,
              !pendingUIDs.contains(key) else { return }
        if remembered.choice(for: key) != nil { pendingChanges.append(key) }
        else { pendingUIDs.append(key) }
        presentNextIfIdle()
    }

    func requestChange(for key: String) {
        guard remembered.choice(for: key) != nil, !pendingChanges.contains(key) else { return }
        pendingChanges.append(key)
        presentNextIfIdle()
    }

    private func saveSelection(_ selection: PromptSelection, for key: String,
                               name: String, device: InputDevice?) {
        if device != nil { _ = applyChoice(selection.microphone, device: device) }
        if selection.remember {
            remembered.save(RememberedChoice(microphone: selection.microphone, deviceName: name), for: key)
            notifications.requestPermission()
            log("Remembered \(selection.microphone.rawValue) microphone for \(name)")
        } else if remembered.choice(for: key) != nil {
            remembered.forget(key)
            log("Forgot microphone choice for \(name)")
        }
    }

    private func presentNextIfIdle() {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        while !pendingChanges.isEmpty || !pendingUIDs.isEmpty {
            if !pendingChanges.isEmpty {
                let key = pendingChanges.removeFirst()
                guard let saved = remembered.choice(for: key) else { continue }
                let device = bluetoothInputs().first(where: { $0.connectionKey == key })
                if let selection = askAbout(name: device?.name ?? saved.deviceName,
                                            device: device, saved: saved) {
                    saveSelection(selection, for: key,
                                  name: device?.name ?? saved.deviceName, device: device)
                }
                continue
            }
            let key = pendingUIDs.removeFirst()
            guard bluetooth.availableKeys(from: [key]).contains(key),
                  let device = bluetoothInputs().first(where: { $0.connectionKey == key }) else { continue }
            connections.beginPrompt(for: key)
            if let saved = remembered.choice(for: key),
               applyChoice(saved.microphone, device: device) {
                notifications.showAppliedChoice(saved, for: key)
                log("Applied remembered choice for \(device.name)")
            } else if let selection = askAbout(name: device.name, device: device,
                                               saved: remembered.choice(for: key)) {
                saveSelection(selection, for: key, name: device.name, device: device)
            }
            connections.endPrompt(for: key)
        }
    }
}

if CommandLine.arguments.contains("--probe") {
    for device in bluetoothInputs() { print("\(device.name)\t\(device.uid)") }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let notifications = ChoiceNotifications()
    if !CommandLine.arguments.contains("--test-prompt") { notifications.start() }
    app.finishLaunching()

    if CommandLine.arguments.contains("--test-prompt") {
        if let device = bluetoothInputs().first { _ = askAbout(name: device.name, device: device) }
        else { log("No connected Bluetooth microphone to test") }
    } else {
        // Homebrew manages its own service, so it passes --no-login-item.
        if !CommandLine.arguments.contains("--no-login-item") {
            registerLoginItemIfNeeded()
        }
        let monitor = MicrophoneMonitor(notifications: notifications)
        notifications.onChangeChoice = { [weak monitor] key in monitor?.requestChange(for: key) }
        monitor.start()
        Darwin.signal(SIGUSR1, SIG_IGN)
        let diagnosticSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        diagnosticSignal.setEventHandler {
            monitor.requestDiagnosticPrompt()
        }
        diagnosticSignal.resume()
        app.run()
    }
}
