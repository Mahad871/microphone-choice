import Foundation

@main
enum ConnectionTrackerTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1000)
        func moment(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        assert(bluetoothConnectionKey("AA-BB:input") == "AA-BB")
        assert(bluetoothConnectionKey("AA-BB:output") == "AA-BB")
        assert(bluetoothConnectionKey("unusual-device-id") == "unusual-device-id")

        var tracker = ConnectionTracker(initialInputKeys: [], connectedKeys: [],
                                        at: moment(0), absenceGrace: 10)
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(0)) == ["headset"])
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(1)).isEmpty)
        tracker.beginPrompt(for: "headset")

        // Core Audio may temporarily remove the input while switching microphones.
        assert(tracker.newlyConnected([], connectedKeys: ["headset"], at: moment(2)).isEmpty)
        assert(tracker.newlyConnected([], connectedKeys: [], at: moment(15)).isEmpty)
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(20)).isEmpty)
        tracker.endPrompt(for: "headset", at: moment(28))
        assert(tracker.newlyConnected([], connectedKeys: ["headset"], at: moment(40)).isEmpty)
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(45)).isEmpty)
        assert(tracker.newlyConnected([], connectedKeys: ["headset"], at: moment(100)).isEmpty)
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(101)).isEmpty)

        // A sustained absence permits a new prompt on the next real connection.
        assert(tracker.newlyConnected([], connectedKeys: [], at: moment(102)).isEmpty)
        assert(tracker.newlyConnected([], connectedKeys: [], at: moment(112)).isEmpty)
        assert(tracker.newlyConnected(["headset"], connectedKeys: ["headset"],
                                      at: moment(113)) == ["headset"])

        // Another device can be queued while the first dialog is open.
        assert(tracker.newlyConnected(["headset", "speakerphone"],
                                      connectedKeys: ["headset", "speakerphone"],
                                      at: moment(114)) == ["speakerphone"])

        var startup = ConnectionTracker(initialInputKeys: ["already-connected"],
                                        connectedKeys: ["already-connected"], at: moment(0))
        assert(startup.newlyConnected(["already-connected"], connectedKeys: ["already-connected"],
                                      at: moment(1)).isEmpty)

        var outputOnly = ConnectionTracker(initialInputKeys: [],
                                           connectedKeys: ["output-only"], at: moment(0))
        assert(outputOnly.newlyConnected(["output-only"], connectedKeys: ["output-only"],
                                         at: moment(1)) == ["output-only"])
        print("Connection tracking passed")
    }
}
