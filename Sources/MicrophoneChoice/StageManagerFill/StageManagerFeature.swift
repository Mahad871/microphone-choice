import AppKit

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

    func fillFocusedWindow() -> StageFillOutcome {
        if preview { return .unavailable("Preview mode does not change other windows.") }
        guard preferences.enabled else {
            return .unavailable("Enable Stage Manager Fill in settings first.")
        }
        let pid = candidatePID()
        guard let pid else {
            return .unavailable("Activate the window you want to fill, then use the menu bar item.")
        }
        return windowManager.fillFocusedWindow(of: pid, preferences: preferences)
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
