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

private func askAbout(_ device: InputDevice) {
    if let macMic = builtInMicrophone() {
        guard selectInput(macMic) else {
            log("Could not select the built in microphone")
            return
        }
    }

    let promptScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let alert = NSAlert()
    if let iconURL = Bundle.main.url(forResource: "MicChoice", withExtension: "png"),
       let icon = NSImage(contentsOf: iconURL) {
        alert.icon = icon
    }
    alert.messageText = "Use \(device.name)’s microphone?"
    alert.informativeText = "The Mac microphone keeps Bluetooth headphone playback at higher quality."
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
    log("Showing microphone choice for \(device.name)")

    let timeout = Timer(timeInterval: promptTimeout, repeats: false) { _ in
        NSApp.abortModal()
    }
    RunLoop.main.add(timeout, forMode: .common)
    let answer = alert.runModal()
    positionTimer.invalidate()
    timeout.invalidate()
    alert.window.orderOut(nil)

    if answer == .alertSecondButtonReturn && bluetoothInputs().contains(where: { $0.uid == device.uid }) {
        if selectInput(device.id) { log("Selected \(device.name) microphone") }
        else { log("Headset microphone became unavailable") }
    } else {
        log("Kept Mac microphone")
    }
}

private final class MicrophoneMonitor {
    private var connections = ConnectionTracker(initialInputKeys: [], connectedKeys: [])
    private var pendingUIDs: [String] = []
    private var isPresenting = false
    private var timer: Timer?

    func start() {
        let current = bluetoothInputs()
        connections = ConnectionTracker(initialInputKeys: Set(current.map(\.connectionKey)),
                                        connectedKeys: bluetoothConnectionKeys())
        if let selected = uintProperty(audioSystem, kAudioHardwarePropertyDefaultInputDevice),
           current.contains(where: { $0.id == selected }),
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
        let currentKeys = Set(current.map(\.connectionKey))
        for key in connections.newlyConnected(currentKeys, connectedKeys: bluetoothConnectionKeys())
            where !pendingUIDs.contains(key) {
            pendingUIDs.append(key)
        }
        presentNextIfIdle()
    }

    func requestDiagnosticPrompt() {
        guard !isPresenting, let key = bluetoothInputs().first?.connectionKey,
              !pendingUIDs.contains(key) else { return }
        pendingUIDs.append(key)
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        while !pendingUIDs.isEmpty {
            let key = pendingUIDs.removeFirst()
            guard let device = bluetoothInputs().first(where: { $0.connectionKey == key }) else { continue }
            connections.beginPrompt(for: key)
            askAbout(device)
            connections.endPrompt(for: key)
        }
    }
}

if CommandLine.arguments.contains("--probe") {
    for device in bluetoothInputs() { print("\(device.name)\t\(device.uid)") }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    if CommandLine.arguments.contains("--test-prompt") {
        if let device = bluetoothInputs().first { askAbout(device) }
        else { log("No connected Bluetooth microphone to test") }
    } else {
        // Homebrew manages its own service, so it passes --no-login-item.
        if !CommandLine.arguments.contains("--no-login-item") {
            registerLoginItemIfNeeded()
        }
        let monitor = MicrophoneMonitor()
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
