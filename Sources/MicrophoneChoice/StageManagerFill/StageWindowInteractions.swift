import AppKit
import ApplicationServices

final class StageCompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StageWindowInteractions: NSObject {
    private let preferences: StageFillPreferences
    private let preview: Bool
    var onInvoke: ((StageWindowTarget, Bool) -> Void)?
    var actionInProgress = false
    private var permissionTimer: Timer?
    private var hoverTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var clickSequence = StageClickSequence()
    private var swallowedMouseUp = false
    private var hoverStart: TimeInterval?
    private var candidate: StageWindowTarget?
    private var lastPointer: CGPoint?
    private var lastPID: pid_t?
    private var panel: StageCompanionPanel?
    private var panelTarget: StageWindowTarget?
    private var hoverWorkPending = false
    private let inspectionQueue = DispatchQueue(label: "StageFill.pointer-inspection", qos: .userInitiated)
    private(set) var doubleClickStatus = ""

    init(preferences: StageFillPreferences, preview: Bool) {
        self.preferences = preferences
        self.preview = preview
        super.init()
    }

    func start() {
        refreshConfiguration()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshConfiguration()
        }
    }

    deinit {
        permissionTimer?.invalidate()
        hoverTimer?.invalidate()
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
    }

    func refreshConfiguration() {
        let allowed = preferences.enabled && !preview && AXIsProcessTrusted()
        if allowed && preferences.greenButtonCompanion {
            if hoverTimer == nil {
                let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.checkHover() }
                RunLoop.main.add(timer, forMode: .common)
                hoverTimer = timer
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            dismiss()
        }
        if allowed && preferences.titleBarDoubleClick {
            if eventTap == nil { installTap() }
            doubleClickStatus = eventTap == nil
                ? "Mouse access is unavailable. Check Accessibility access, then try again."
                : "Double-click an empty title-bar area to fill. Double-click again to restore its previous size and position."
        } else {
            if let eventTap { CFMachPortInvalidate(eventTap) }
            if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
            eventTap = nil
            eventSource = nil
            swallowedMouseUp = false
            clickSequence = StageClickSequence()
            doubleClickStatus = preview ? "Preview does not intercept clicks or show controls over other apps."
                : "Double-click to fill, then double-click again to restore. Unrecognized custom title bars keep their normal behavior."
        }
    }

    private func installTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<StageWindowInteractions>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedMouseUp = false
            clickSequence = StageClickSequence()
            if preferences.enabled, preferences.titleBarDoubleClick, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, swallowedMouseUp {
            swallowedMouseUp = false
            return nil
        }
        guard type == .leftMouseDown, preferences.enabled, preferences.titleBarDoubleClick,
              !actionInProgress else {
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard clickSequence.down(at: event.location, time: ProcessInfo.processInfo.systemUptime,
            count: Int(event.getIntegerValueField(.mouseEventClickState)),
            unmodified: event.flags.intersection(modifiers).isEmpty, interval: NSEvent.doubleClickInterval),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let target = StageWindowTargeting.titleBar(at: event.location, pid: app.processIdentifier)
        else { return Unmanaged.passUnretained(event) }
        swallowedMouseUp = true
        DispatchQueue.main.async { [weak self] in
            self?.dismiss()
            self?.onInvoke?(target, true)
        }
        return nil
    }

    private func checkHover() {
        if NSEvent.pressedMouseButtons != 0 { return }
        guard !actionInProgress, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primaryTop = NSScreen.screens.first?.frame.maxY else { dismiss(); return }
        let point = NSEvent.mouseLocation
        let pid = app.processIdentifier
        if let panelTarget, panelTarget.pid != pid { dismiss() }
        if let panel, panel.isVisible, let panelTarget {
            let green = StageFillGeometry.appKitFrame(fromAX: panelTarget.greenButton, primaryTop: primaryTop)
            // A short horizontal bridge makes moving from the green button to
            // the companion forgiving without covering Apple's menu beneath.
            if !green.union(panel.frame).insetBy(dx: -5, dy: -5).contains(point) { dismiss() }
        }
        if point == lastPointer, pid == lastPID, candidate == nil, panelTarget == nil { return }
        lastPointer = point
        lastPID = pid
        guard !hoverWorkPending else { return }
        hoverWorkPending = true
        inspectionQueue.async { [weak self] in
            let target = StageWindowTargeting.focused(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hoverWorkPending = false
                guard self.preferences.enabled, self.preferences.greenButtonCompanion, AXIsProcessTrusted(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let target else { self.dismiss(); return }
                self.updateHover(target, point: NSEvent.mouseLocation, primaryTop: primaryTop)
            }
        }
    }

    private func updateHover(_ target: StageWindowTarget, point: CGPoint, primaryTop: CGFloat) {
        if let panelTarget, (!CFEqual(panelTarget.window, target.window) ||
            panelTarget.greenButton != target.greenButton || panelTarget.frame != target.frame) { dismiss() }
        let green = StageFillGeometry.appKitFrame(fromAX: target.greenButton, primaryTop: primaryTop)
        if panel?.isVisible == true { return }
        guard green.insetBy(dx: -2, dy: -2).contains(point) else {
            candidate = nil
            hoverStart = nil
            return
        }
        if candidate.map({ CFEqual($0.window, target.window) && $0.greenButton == target.greenButton }) != true {
            candidate = target
            hoverStart = ProcessInfo.processInfo.systemUptime
        }
        guard let hoverStart, ProcessInfo.processInfo.systemUptime - hoverStart >= 0.55,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let frame = StageCompanionGeometry.frame(beside: green, visible: screen.visibleFrame) else { return }
        show(target: target, frame: frame)
    }

    private func show(target: StageWindowTarget, frame: CGRect) {
        if panel == nil {
            let panel = StageCompanionPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 9
            material.layer?.masksToBounds = true
            let button = NSButton(title: "Stage Manager Fill", target: self, action: #selector(invokeCompanion))
            button.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.setAccessibilityLabel("Fill this window beside Stage Manager")
            button.toolTip = "Leave the configured space on the left for Stage Manager"
            material.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
                button.topAnchor.constraint(equalTo: material.topAnchor),
                button.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            panel.contentView = material
            self.panel = panel
        }
        panelTarget = target
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    @objc private func invokeCompanion() {
        guard let target = panelTarget, preferences.enabled, preferences.greenButtonCompanion else { return }
        dismiss()
        onInvoke?(target, false)
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panelTarget = nil
        candidate = nil
        hoverStart = nil
    }
}
