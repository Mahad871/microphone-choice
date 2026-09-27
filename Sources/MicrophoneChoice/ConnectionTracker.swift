import Foundation

func bluetoothConnectionKey(_ uid: String) -> String {
    let base: String
    for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
        base = String(uid.dropLast(suffix.count))
        return bluetoothAddressKey(base) ?? base
    }
    return bluetoothAddressKey(uid) ?? uid
}

/// Core Audio and IOBluetooth can use different separators and letter case for one address.
func bluetoothAddressKey(_ address: String) -> String? {
    let octets = address.split(whereSeparator: { $0 == "-" || $0 == ":" })
    guard octets.count == 6, octets.allSatisfy({ octet in
        octet.count == 2 && octet.allSatisfy(\.isHexDigit)
    }) else { return nil }
    return octets.map { $0.uppercased() }.joined(separator: "-")
}

/// Treats brief Core Audio device-list gaps as part of the same connection.
struct ConnectionTracker {
    private let absenceGrace: TimeInterval
    private let postPromptGrace: TimeInterval
    private var promptedKeys: Set<String>
    private var lastSeen: [String: Date]
    private var activePrompts = Set<String>()
    private var protectedUntil: [String: Date] = [:]

    init(initialInputKeys: Set<String>, connectedKeys: Set<String>, at now: Date = Date(),
         absenceGrace: TimeInterval = 10, postPromptGrace: TimeInterval = 30) {
        self.absenceGrace = absenceGrace
        self.postPromptGrace = postPromptGrace
        promptedKeys = initialInputKeys
        lastSeen = Dictionary(uniqueKeysWithValues: connectedKeys.union(initialInputKeys).map { ($0, now) })
    }

    mutating func beginPrompt(for uid: String) {
        activePrompts.insert(uid)
    }

    mutating func endPrompt(for uid: String, at now: Date = Date()) {
        activePrompts.remove(uid)
        protectedUntil[uid] = now.addingTimeInterval(postPromptGrace)
        lastSeen[uid] = now
    }

    /// A real Bluetooth disconnect ends this connection even if Core Audio still lists it.
    mutating func physicallyDisconnected(_ uid: String) {
        promptedKeys.remove(uid)
        protectedUntil.removeValue(forKey: uid)
        lastSeen.removeValue(forKey: uid)
    }

    mutating func newlyConnected(_ inputKeys: Set<String>, connectedKeys: Set<String>,
                                 at now: Date = Date()) -> [String] {
        for key in connectedKeys.union(inputKeys) {
            lastSeen[key] = now
        }

        let expired = lastSeen.compactMap { uid, seenAt in
            let isProtected = activePrompts.contains(uid) || now < (protectedUntil[uid] ?? .distantPast)
            return !connectedKeys.contains(uid) && !inputKeys.contains(uid) && !isProtected &&
                now.timeIntervalSince(seenAt) >= absenceGrace ? uid : nil
        }
        for uid in expired {
            lastSeen.removeValue(forKey: uid)
            promptedKeys.remove(uid)
            protectedUntil.removeValue(forKey: uid)
        }

        let added = inputKeys.subtracting(promptedKeys).sorted()
        promptedKeys.formUnion(added)
        return added
    }
}
