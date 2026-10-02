import AppKit
import ApplicationServices

/// Opt-in test: opens two disposable windows in a child process and exercises
/// the real Accessibility resize path. Requires a logged-in desktop and AX access.
@main
struct StageFillLiveTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if CommandLine.arguments.contains("--fixture") {
            let windows = (0..<2).map { index -> NSWindow in
                let window = NSWindow(contentRect: CGRect(x: 450 + index * 80, y: 280,
                    width: 620 - index * 80, height: 400),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Stage Fill Test \(index)"
                window.orderFront(nil)
                return window
            }
            withExtendedLifetime(windows) { app.run() }
            return
        }
        guard AXIsProcessTrusted(), let primaryTop = NSScreen.screens.first?.frame.maxY else {
            fputs("Live tests need a desktop session and Accessibility access for the terminal running them.\n", stderr)
            exit(1)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fixture"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let application = AXUIElementCreateApplication(child.processIdentifier)
        var windows: [AXUIElement] = []
        for _ in 0..<50 {
            windows = (StageWindowTargeting.value(kAXWindowsAttribute, of: application)
                as? [AXUIElement] ?? []).filter {
                (StageWindowTargeting.value(kAXTitleAttribute, of: $0) as? String)?.hasPrefix("Stage Fill Test ") == true
            }
            if windows.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try require(windows.count == 2, "Disposable test windows did not open")
        let original = try windows.map { window -> CGRect in
            guard let frame = StageWindowTargeting.frame(of: window) else {
                throw Failure(message: "Missing window frame")
            }
            return frame
        }
        let suite = "stage-fill-live-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StageFillPreferences(defaults: defaults)
        let manager = StageFillWindowManager()
        let displays = StageDisplay.connected()
        func run(_ index: Int, toggle: Bool = true) -> StageFillOutcome {
            let outcome = manager.fill(window: windows[index], preferences: preferences,
                displays: displays, primaryScreenTop: primaryTop, toggle: toggle)
            print(outcome)
            return outcome
        }
        func requireFill(_ result: StageFillOutcome) throws {
            guard case .filled = result else { throw Failure(message: "Fill failed: \(result)") }
        }
        func requireRestore(_ result: StageFillOutcome, original: CGRect) throws {
            guard case .restored(_, let actual) = result,
                  StageRestoreState.matches(actual, original) else {
                throw Failure(message: "Exact restore failed: \(result)")
            }
        }
        try requireFill(run(0))
        try requireFill(run(1))
        try requireFill(run(0, toggle: false))
        try requireRestore(run(0), original: original[0])
        try require(StageWindowTargeting.frame(of: windows[1]).map {
            !StageRestoreState.matches($0, original[1])
        } == true, "Restoring one window changed the other")
        try requireRestore(run(1), original: original[1])
        try requireFill(run(0))
        try requireRestore(run(0), original: original[0])
        print("Live AX checks passed: independent windows, exact restore, repeated Fill, repeated toggle")
    }

    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
