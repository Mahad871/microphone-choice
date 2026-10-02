import Foundation

@main
struct StageFillTests {
    static func main() {
        let primary = StageDisplay(key: "built-in", name: "Built-in", frame:
            CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame:
            CGRect(x: 0, y: 0, width: 1440, height: 860))
        let external = StageDisplay(key: "external", name: "External", frame:
            CGRect(x: 1440, y: -180, width: 1920, height: 1080), visibleFrame:
            CGRect(x: 1440, y: -140, width: 1920, height: 1000))
        let leftDisplay = StageDisplay(key: "left", name: "Left", frame:
            CGRect(x: -1280, y: -100, width: 1280, height: 800), visibleFrame:
            CGRect(x: -1280, y: -60, width: 1280, height: 720))
        let primaryTarget = StageFillGeometry.targetFrame(for: primary, reservation: 220, primaryTop: 900)
        assert(primaryTarget == CGRect(x: 220, y: 40, width: 1220, height: 860))
        assert(StageFillGeometry.appKitFrame(fromAX: primaryTarget, primaryTop: 900) ==
            CGRect(x: 220, y: 0, width: 1220, height: 860))
        let crossing = StageFillGeometry.axFrame(fromAppKit:
            CGRect(x: 1300, y: 100, width: 600, height: 500), primaryTop: 900)
        assert(StageFillGeometry.displayContainingMost(of: crossing, displays: [primary, external],
            primaryTop: 900)?.key == external.key)
        let externalTarget = StageFillGeometry.targetFrame(for: external, reservation: 280, primaryTop: 900)
        assert(externalTarget == CGRect(x: 1720, y: 40, width: 1640, height: 1000))
        let leftTarget = StageFillGeometry.targetFrame(for: leftDisplay, reservation: 220, primaryTop: 900)
        assert(leftTarget == CGRect(x: -1060, y: 240, width: 1060, height: 720))
        assert(StageFillGeometry.displayContainingMost(of: CGRect(x: 9000, y: 0, width: 100, height: 100),
            displays: [primary, external], primaryTop: 900) == nil)
        assert(StageFillGeometry.coversEntireDisplay(
            StageFillGeometry.axFrame(fromAppKit: primary.frame, primaryTop: 900),
            display: primary, primaryTop: 900))
        assert(!StageFillGeometry.coversEntireDisplay(primaryTarget, display: primary, primaryTop: 900))
        let small = StageDisplay(key: "small", name: "Small", frame:
            CGRect(x: 0, y: 0, width: 400, height: 300), visibleFrame:
            CGRect(x: 0, y: 0, width: 400, height: 280))
        assert(StageFillGeometry.targetFrame(for: small, reservation: 500, primaryTop: 300) ==
            CGRect(x: 200, y: 20, width: 200, height: 280))

        let suite = "io.github.mahad871.microphonechoice.stage.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StageFillPreferences(defaults: defaults)
        assert(preferences.enabled && !preferences.rememberPerDisplay)
        assert(preferences.defaultReservation == 220)
        preferences.setReservation(230, for: external.key)
        assert(preferences.defaultReservation == 230)
        preferences.rememberPerDisplay = true
        preferences.setReservation(280, for: external.key)
        preferences.setReservation(240, for: primary.key)
        assert(preferences.reservation(for: external.key) == 280)
        assert(preferences.reservation(for: primary.key) == 240)
        assert(preferences.reservation(for: leftDisplay.key) == 230)
        preferences.enabled = false
        let reloaded = StageFillPreferences(defaults: defaults)
        assert(!reloaded.enabled && reloaded.rememberPerDisplay)
        assert(reloaded.reservation(for: external.key) == 280)
        reloaded.rememberPerDisplay = false
        assert(reloaded.reservation(for: external.key) == 230)
        reloaded.defaultReservation = 9000
        assert(reloaded.defaultReservation == StageFillPreferences.maximumReservation)
        print("Stage Fill geometry, display selection, and preferences passed")
    }
}
