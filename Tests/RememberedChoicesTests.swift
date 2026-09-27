import Foundation

func checkRememberedChoices() {
    let suiteName = "io.github.mahad871.microphonechoice.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { assertionFailure(); return }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = RememberedChoices(defaults: defaults)
    let mac = RememberedChoice(microphone: .preferred, deviceName: "Headset A")
    let bluetooth = RememberedChoice(microphone: .bluetooth, deviceName: "Headset B")
    assert(store.choice(for: "A") == nil)
    store.save(mac, for: "A")
    store.save(bluetooth, for: "B")

    let reloaded = RememberedChoices(defaults: defaults)
    assert(reloaded.choice(for: "A") == mac)
    assert(reloaded.choice(for: "B") == bluetooth)

    reloaded.save(RememberedChoice(microphone: .bluetooth, deviceName: "Headset A"), for: "A")
    assert(store.choice(for: "A")?.microphone == .bluetooth)
    reloaded.forget("A")
    assert(store.choice(for: "A") == nil)
    assert(store.choice(for: "B") == bluetooth)
    assert(MicrophoneChoice(rawValue: "mac") == .preferred)
    print("Remembered choices passed")
}
