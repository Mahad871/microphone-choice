import AppKit
import ApplicationServices

/// Remembers the app that owned focus before the menu bar utility opens its
/// menu. Querying the frontmost app only after menu activation can select this
/// utility's own settings window instead of the window the user was working in.
final class StageManagerFeature {
    let preferences: StageFillPreferences
    private let windowManager = StageFillWindowManager()
    private let preview: Bool
    private var activationObserver: NSObjectProtocol?
    private var lastExternalPID: pid_t?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private lazy var interactions = StageWindowInteractions(preferences: preferences, preview: preview)
    private let fillQueue = DispatchQueue(label: "StageFill.window-actions", qos: .userInitiated)
    var onInteractionResult: ((StageFillOutcome) -> Void)?

    var interactionStatus: String { interactions.doubleClickStatus }

    func startInteractions() {
        interactions.onInvoke = { [weak self] target, toggle in self?.fillCapturedWindow(target, toggle: toggle) }
        interactions.start()
    }

    func refreshInteractions() { interactions.refreshConfiguration() }

    private func fillCapturedWindow(_ target: StageWindowTarget, toggle: Bool) {
        guard !preview, preferences.enabled, !interactions.actionInProgress,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let focused = StageWindowTargeting.focused(pid: target.pid),
              CFEqual(focused.window, target.window) else { return }
        enqueue(window: target.window, toggle: toggle) { [weak self] outcome in self?.onInteractionResult?(outcome) }
    }

    private func enqueue(window: AXUIElement, toggle: Bool = false,
                         completion: @escaping (StageFillOutcome) -> Void) {
        guard !interactions.actionInProgress else {
            completion(.unavailable("A window fill is already in progress."))
            return
        }
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else {
            completion(.unavailable("Screen geometry is unavailable."))
            return
        }
        let displays = StageDisplay.connected()
        interactions.actionInProgress = true
        fillQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.windowManager.fill(window: window, preferences: self.preferences,
                                                  displays: displays, primaryScreenTop: primaryTop,
                                                  toggle: toggle)
            DispatchQueue.main.async {
                self.interactions.actionInProgress = false
                completion(outcome)
            }
        }
    }

    init(preferences: StageFillPreferences, preview: Bool = false) {
        self.preferences = preferences
        self.preview = preview
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != self.ownPID else { return }
            self.lastExternalPID = application.processIdentifier
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    var targetAppName: String? {
        guard let pid = candidatePID() else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid
        }?.localizedName
    }

    func requestFillFocusedWindow(completion: @escaping (StageFillOutcome) -> Void) {
        if preview { completion(.unavailable("Preview mode does not change other windows.")); return }
        guard preferences.enabled else {
            completion(.unavailable("Enable Stage Manager Fill in settings first."))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.needsAccessibility)
            return
        }
        let pid = candidatePID()
        guard let pid else {
            completion(.unavailable("Activate the window you want to fill, then use the menu bar item."))
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = StageWindowTargeting.element(kAXFocusedWindowAttribute, of: app) else {
            completion(.unavailable("The selected app has no focused window to resize."))
            return
        }
        enqueue(window: window, completion: completion)
    }

    private func candidatePID() -> pid_t? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
            return frontmost.processIdentifier
        }
        return lastExternalPID
    }
}
