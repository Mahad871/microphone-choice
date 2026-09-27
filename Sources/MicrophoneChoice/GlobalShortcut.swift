import Carbon
import Foundation

final class GlobalShortcut {
    var onInvoke: (() -> Void)?
    private(set) var status = "Off"
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var registeredConfiguration: ShortcutConfiguration?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4D696343 else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            guard identifier.id == 1, shortcut.hotKey != nil else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { [weak shortcut] in shortcut?.onInvoke?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if result != noErr { status = "Could not initialize shortcut (\(result))." }
    }

    @discardableResult
    func configure(_ configuration: ShortcutConfiguration) -> String? {
        if let error = configuration.validationError { return error }
        guard configuration.enabled else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            registeredConfiguration = nil
            status = "Off"
            return nil
        }
        if registeredConfiguration == configuration, hotKey != nil { return nil }
        guard handler != nil else { return status }
        var modifiers: UInt32 = 0
        if configuration.control { modifiers |= UInt32(controlKey) }
        if configuration.option { modifiers |= UInt32(optionKey) }
        if configuration.shift { modifiers |= UInt32(shiftKey) }
        if configuration.command { modifiers |= UInt32(cmdKey) }
        var newHotKey: EventHotKeyRef?
        let result = RegisterEventHotKey(ShortcutConfiguration.keyCodes[configuration.key]!, modifiers,
            EventHotKeyID(signature: 0x4D696343, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &newHotKey)
        guard result == noErr else {
            let reason = "That shortcut is unavailable or used by another app. Choose another combination."
            if hotKey == nil { status = reason }
            return reason
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = newHotKey
        registeredConfiguration = configuration
        status = configuration.displayName
        return nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
