import CoreAudio
import Foundation

private let audioSystem = AudioObjectID(kAudioObjectSystemObject)

struct InputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool

    var connectionKey: String { bluetoothConnectionKey(uid) }
    var displayName: String { uid == "BuiltInMicrophoneDevice" ? "Mac microphone" : name }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
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

func uintProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
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
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr &&
        size >= MemoryLayout<AudioStreamID>.size
}

private func isBluetooth(_ id: AudioDeviceID) -> Bool {
    guard let transport = uintProperty(id, kAudioDevicePropertyTransportType) else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
}

func inputDevices() -> [InputDevice] {
    deviceIDs().compactMap { id in
        guard hasInputStream(id),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return InputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id))
    }.sorted {
        if ($0.uid == "BuiltInMicrophoneDevice") != ($1.uid == "BuiltInMicrophoneDevice") {
            return $0.uid == "BuiltInMicrophoneDevice"
        }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

func bluetoothInputs() -> [InputDevice] { inputDevices().filter(\.isBluetooth) }

func bluetoothConnectionKeys() -> Set<String> {
    Set(deviceIDs().compactMap { id in
        guard isBluetooth(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return bluetoothConnectionKey(uid)
    })
}

/// A missing USB microphone falls back to the built-in input, then another non-Bluetooth input.
func preferredMicrophone(in devices: [InputDevice], configuredUID: String?) -> InputDevice? {
    let candidates = devices.filter { !$0.isBluetooth }
    if let configuredUID, let configured = candidates.first(where: { $0.uid == configuredUID }) {
        return configured
    }
    return candidates.first { $0.uid == "BuiltInMicrophoneDevice" } ?? candidates.first
}

func preferredMicrophone(_ configuredUID: String?) -> InputDevice? {
    preferredMicrophone(in: inputDevices(), configuredUID: configuredUID)
}

func currentInputDevice() -> InputDevice? {
    guard let id = uintProperty(audioSystem, kAudioHardwarePropertyDefaultInputDevice) else { return nil }
    return inputDevices().first { $0.id == id }
}

@discardableResult
func selectInput(_ id: AudioDeviceID) -> Bool {
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    var selected = id
    return AudioObjectSetPropertyData(audioSystem, &address, 0, nil,
                                     UInt32(MemoryLayout<AudioDeviceID>.size), &selected) == noErr
}
