import AppKit
import ApplicationServices
import ServiceManagement

extension AppTheme {
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class DesktopController: NSObject, NSMenuDelegate, NSApplicationDelegate {
    var onTermination: (() -> Void)?
    private let monitor: MicrophoneMonitor
    private let login: LoginController
    private let shortcut: GlobalShortcut
    private let stageFill: StageManagerFeature
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var panels: [NSView] = []
    private let tabs = NSSegmentedControl(labels: ["General", "Saved devices", "Diagnostics", "Stage Manager Fill"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let preferredPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let fallbackDetail = NSTextField(wrappingLabelWithString: "")
    private let loginSwitch = NSSwitch()
    private let loginDetail = NSTextField(wrappingLabelWithString: "")
    private let notificationSwitch = NSSwitch()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutSwitch = NSSwitch()
    private let modifiers = NSSegmentedControl(labels: ["⌃", "⌥", "⇧", "⌘"],
                                               trackingMode: .selectAny, target: nil, action: nil)
    private let shortcutKey = NSPopUpButton()
    private let shortcutDetail = NSTextField(wrappingLabelWithString: "")
    private let savedStack = NSStackView()
    private let undoButton = NSButton(title: "Undo forget", target: nil, action: nil)
    private let reportView = NSTextView()
    private let stageEnableSwitch = NSSwitch()
    private let stagePerDisplaySwitch = NSSwitch()
    private let stageDisplayPopup = NSPopUpButton()
    private let stageWidthField = NSTextField()
    private let stageSaveWidthButton = NSButton(title: "Save width", target: nil, action: nil)
    private let stageActionButton = NSButton(title: "Fill last active window", target: nil, action: nil)
    private let stageWidthDescription = NSTextField(wrappingLabelWithString: "")
    private let stagePermissionLabel = NSTextField(wrappingLabelWithString: "")
    private let stageResultLabel = NSTextField(wrappingLabelWithString: "")
    private var inputSignature = ""
    private var savedSignature = ""
    private var displaySignature = ""
    private var shortcutError: String?

    init(monitor: MicrophoneMonitor, login: LoginController, shortcut: GlobalShortcut,
         stageFill: StageManagerFeature) {
        self.monitor = monitor
        self.login = login
        self.shortcut = shortcut
        self.stageFill = stageFill
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone Choice")
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        statusItem?.button?.setAccessibilityLabel("Microphone Choice")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem?.menu = menu
        buildMainMenu()
        refresh()
    }

    func refresh() {
        statusItem?.button?.toolTip = "Microphone Choice — \(currentInputDevice()?.displayName ?? "No microphone")"
        guard settingsWindow?.isVisible == true else { return }
        refreshGeneral()
        refreshSavedDevices()
        refreshStageFill()
        let report = monitor.diagnosticReport(shortcutStatus: shortcut.status)
        if reportView.string != report { reportView.string = report }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let fill = item("Stage Manager Fill", action: #selector(fillStageManager))
        fill.isEnabled = stageFill.preferences.enabled
        fill.image = NSImage(systemSymbolName: "rectangle.inset.filled",
                             accessibilityDescription: "Fill beside Stage Manager")
        menu.addItem(fill)
        if let appName = stageFill.targetAppName {
            menu.addItem(item("Window from: \(appName)", enabled: false))
        }
        menu.addItem(item("Stage Manager Fill settings…", action: #selector(openStageSettings)))
        menu.addItem(.separator())
        let current = currentInputDevice()
        menu.addItem(item("Current: \(current?.displayName ?? "No microphone")", enabled: false))
        let inputsMenu = NSMenu(title: "Switch input")
        inputsMenu.autoenablesItems = false
        for device in inputDevices() {
            let entry = item(device.displayName, action: #selector(selectInputFromMenu(_:)))
            entry.representedObject = device.uid
            entry.state = device.uid == current?.uid ? .on : .off
            inputsMenu.addItem(entry)
        }
        if inputsMenu.items.isEmpty { inputsMenu.addItem(item("No input devices available", enabled: false)) }
        let inputs = item("Switch input")
        inputs.submenu = inputsMenu
        menu.addItem(inputs)
        menu.addItem(item("Use preferred microphone", action: #selector(usePreferred),
                          enabled: monitor.preferredInput != nil))
        let bluetooth = monitor.connectedBluetoothInputs
        if bluetooth.count == 1 {
            let entry = item("Choose microphone for \(bluetooth[0].name)…", action: #selector(openChoiceFromMenu(_:)))
            entry.representedObject = bluetooth[0].connectionKey
            menu.addItem(entry)
        } else if !bluetooth.isEmpty {
            let choices = NSMenu()
            choices.autoenablesItems = false
            for device in bluetooth {
                let entry = item(device.name, action: #selector(openChoiceFromMenu(_:)))
                entry.representedObject = device.connectionKey
                choices.addItem(entry)
            }
            let choiceItem = item("Choose Bluetooth microphone…")
            choiceItem.submenu = choices
            menu.addItem(choiceItem)
        } else { menu.addItem(item("No Bluetooth microphone connected", enabled: false)) }
        menu.addItem(.separator())
        menu.addItem(item("Saved devices…", action: #selector(openSavedDevices)))
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("Connection diagnostics…", action: #selector(openDiagnostics)))
        menu.addItem(item("Test popup", action: #selector(testPopup)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Microphone Choice", action: #selector(quit), key: "q"))
    }

    func showChoiceOrSettings() {
        if let device = monitor.connectedBluetoothInputs.first {
            monitor.requestChoice(for: device.connectionKey)
        } else { showSettings(tab: 0) }
    }

    func showSettings(tab: Int) {
        if settingsWindow == nil { buildSettingsWindow() }
        tabs.selectedSegment = tab
        selectPanel(tab)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        monitor.notifications.refreshPermission()
        refresh()
    }

    private func buildSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Microphone Choice"
        window.minSize = NSSize(width: 640, height: 590)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MicrophoneChoiceSettings")
        window.center()
        settingsWindow = window
        guard let root = window.contentView else { return }
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        for (index, tip) in ["Microphone and app settings", "Manage remembered devices",
                             "Connection status and testing", "Resize the focused window beside Stage Manager"].enumerated() {
            tabs.setToolTip(tip, forSegment: index)
        }
        tabs.setAccessibilityLabel("Settings section")
        let host = NSView()
        let layout = stack([tabs, host], vertical: true, spacing: 20)
        root.addSubview(layout)
        pin(layout, to: root, inset: 24)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 30).isActive = true
        panels = [makeGeneralPanel(), makeSavedPanel(), makeDiagnosticsPanel(), makeStagePanel()]
        for panel in panels { host.addSubview(panel); pin(panel, to: host) }
        selectPanel(0)
    }

    private func makeGeneralPanel() -> NSView {
        preferredPopup.target = self
        preferredPopup.menu?.autoenablesItems = false
        preferredPopup.action = #selector(preferredChanged)
        preferredPopup.setAccessibilityLabel("Preferred microphone")
        preferredPopup.toolTip = "Used instead of a Bluetooth microphone, including for remembered choices."
        let preferred = stack([heading("Preferred microphone"), preferredPopup, secondary(fallbackDetail)],
                               vertical: true, spacing: 7)
        preferredPopup.widthAnchor.constraint(equalToConstant: 440).isActive = true
        themePopup.addItems(withTitles: AppTheme.allCases.map(\.title))
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        themePopup.setAccessibilityLabel("Appearance")
        themePopup.toolTip = "System follows your Mac's light or dark appearance automatically."
        themePopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let themeRow = stack([heading("Appearance"), themePopup], vertical: false, spacing: 18)
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        loginSwitch.setAccessibilityLabel("Start at login")
        let loginItems = NSButton(title: "Login Items…", target: self, action: #selector(openLoginItems))
        let loginRow = switchRow(loginSwitch, title: "Start at login", trailing: loginItems)
        let loginGroup = stack([loginRow, secondary(loginDetail)], vertical: true, spacing: 4)
        notificationSwitch.target = self
        notificationSwitch.action = #selector(notificationsChanged)
        notificationSwitch.setAccessibilityLabel("Notify when a saved choice is applied")
        let notificationSettings = NSButton(title: "Notification settings…", target: self,
                                            action: #selector(openNotificationSettings))
        let notificationGroup = stack([
            switchRow(notificationSwitch, title: "Notify when a saved choice is applied"),
            stack([secondary(permissionLabel), notificationSettings], vertical: false, spacing: 12)
        ], vertical: true, spacing: 4)
        shortcutSwitch.target = self
        shortcutSwitch.action = #selector(shortcutChanged)
        shortcutSwitch.setAccessibilityLabel("Enable global keyboard shortcut")
        modifiers.target = self
        modifiers.action = #selector(shortcutChanged)
        modifiers.setAccessibilityLabel("Shortcut modifiers")
        for (index, title) in ["Control", "Option", "Shift", "Command"].enumerated() {
            modifiers.setToolTip(title, forSegment: index)
            modifiers.setWidth(48, forSegment: index)
        }
        shortcutKey.addItems(withTitles: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init))
        shortcutKey.target = self
        shortcutKey.action = #selector(shortcutChanged)
        shortcutKey.setAccessibilityLabel("Shortcut key")
        let shortcutControls = stack([modifiers, shortcutKey], vertical: false, spacing: 8)
        shortcutKey.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let shortcutGroup = stack([
            switchRow(shortcutSwitch, title: "Global keyboard shortcut"),
            shortcutControls, secondary(shortcutDetail),
            note("Opens the microphone choice for a connected Bluetooth device, or settings when none is connected.")
        ], vertical: true, spacing: 7)
        let panel = stack([preferred, themeRow, separator(), loginGroup, notificationGroup, separator(), shortcutGroup],
                          vertical: true, spacing: 15)
        for view in [preferred, loginGroup, notificationGroup, shortcutGroup] {
            view.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        }
        // Keep the content at the top when the settings window grows.
        let host = NSView()
        host.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)
        ])
        return host
    }

    private func makeSavedPanel() -> NSView {
        savedStack.orientation = .vertical
        savedStack.alignment = .leading
        savedStack.spacing = 16
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = FlippedDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(savedStack)
        pin(savedStack, to: document, inset: 8)
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        undoButton.target = self
        undoButton.action = #selector(undoForget)
        let panel = stack([
            heading("Remembered devices"),
            note("Changes apply now when a device is connected, and on future connections. Forgetting a choice leaves the current input unchanged."),
            scroll, undoButton
        ], vertical: true, spacing: 12)
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return panel
    }

    private func makeDiagnosticsPanel() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        reportView.textContainerInset = NSSize(width: 12, height: 12)
        reportView.isVerticallyResizable = true
        reportView.isHorizontallyResizable = false
        reportView.autoresizingMask = [.width]
        reportView.textContainer?.widthTracksTextView = true
        reportView.setAccessibilityLabel("Connection diagnostic report")
        scroll.documentView = reportView
        let test = NSButton(title: "Test popup", target: self, action: #selector(testPopup))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshDiagnostics))
        let copy = NSButton(title: "Copy report", target: self, action: #selector(copyReport(_:)))
        let panel = stack([heading("Connection diagnostics"),
            note("See what the app detected and why a popup appeared or was skipped. The report stays local and excludes device identifiers."),
            scroll, stack([test, refresh, copy], vertical: false, spacing: 10)
        ], vertical: true, spacing: 12)
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return panel
    }

    private func makeStagePanel() -> NSView {
        stageEnableSwitch.target = self
        stageEnableSwitch.action = #selector(stageEnabledChanged)
        stageEnableSwitch.setAccessibilityLabel("Enable Stage Manager Fill")
        stagePerDisplaySwitch.target = self
        stagePerDisplaySwitch.action = #selector(stagePerDisplayChanged)
        stagePerDisplaySwitch.setAccessibilityLabel("Remember a width for each display")
        stageDisplayPopup.target = self
        stageDisplayPopup.action = #selector(stageDisplayChanged)
        stageDisplayPopup.setAccessibilityLabel("Display to configure")
        stageDisplayPopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        stageWidthField.setAccessibilityLabel("Reserved width in screen points")
        stageWidthField.alignment = .right
        stageWidthField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        stageSaveWidthButton.target = self
        stageSaveWidthButton.action = #selector(saveStageWidth)
        let widthRow = stack([stageWidthField, NSTextField(labelWithString: "pt"), stageSaveWidthButton],
                             vertical: false, spacing: 10)
        stageActionButton.target = self
        stageActionButton.action = #selector(fillStageManager)
        let accessibilityButton = NSButton(title: "Open Accessibility Settings…", target: self,
                                            action: #selector(openAccessibilitySettings))
        let refreshAccess = NSButton(title: "Check access", target: self,
                                     action: #selector(checkStageAccess))
        let panel = stack([
            heading("Stage Manager Fill"),
            note("Fill the last active app window while leaving space on the left for Stage Manager. Apple's green button and tiling menu stay unchanged."),
            separator(),
            switchRow(stageEnableSwitch, title: "Enable Stage Manager Fill"),
            switchRow(stagePerDisplaySwitch, title: "Remember a width for each display"),
            stageDisplayPopup,
            heading("Reserved width"),
            widthRow,
            secondary(stageWidthDescription),
            separator(),
            heading("Accessibility"),
            secondary(stagePermissionLabel),
            stack([accessibilityButton, refreshAccess], vertical: false, spacing: 10),
            separator(),
            stageActionButton,
            secondary(stageResultLabel)
        ], vertical: true, spacing: 11)
        // Let the last status label take spare space; keep controls at the top
        // on a taller window and allow a compact window to scroll.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        document.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: document.topAnchor, constant: 3),
            panel.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }

    private func selectPanel(_ index: Int) {
        for (position, panel) in panels.enumerated() { panel.isHidden = position != index }
        refresh()
    }

    private func refreshGeneral() {
        let settings = monitor.settings
        themePopup.selectItem(withTitle: settings.theme.title)
        let devices = inputDevices().filter { !$0.isBluetooth }
        let signature = devices.map { "\($0.uid):\($0.name)" }.joined(separator: "|") +
            (settings.preferredInputUID ?? "") + (settings.preferredInputName ?? "")
        if signature != inputSignature {
            preferredPopup.removeAllItems()
            preferredPopup.addItem(withTitle: "Automatic (Mac microphone when available)")
            preferredPopup.lastItem?.representedObject = ""
            for device in devices {
                preferredPopup.addItem(withTitle: device.displayName)
                preferredPopup.lastItem?.representedObject = device.uid
            }
            if let uid = settings.preferredInputUID, !devices.contains(where: { $0.uid == uid }) {
                preferredPopup.addItem(withTitle: "\(settings.preferredInputName ?? "Preferred microphone") (not connected)")
                preferredPopup.lastItem?.representedObject = uid
                preferredPopup.lastItem?.isEnabled = false
            }
            inputSignature = signature
        }
        preferredPopup.select(preferredPopup.itemArray.first {
            ($0.representedObject as? String) == (settings.preferredInputUID ?? "")
        })
        fallbackDetail.stringValue = "Available now: \(monitor.preferredInput?.displayName ?? "No non-Bluetooth input"). If your preferred microphone is unplugged, the Mac microphone or another non-Bluetooth input is used."
        loginSwitch.state = login.enabled ? .on : .off
        loginDetail.stringValue = login.detail
        notificationSwitch.state = settings.notificationsEnabled ? .on : .off
        permissionLabel.stringValue = monitor.preview ? "Preview: permission will be requested when you enable notifications in the app." :
            monitor.notifications.permissionStatus
        let config = settings.shortcut
        shortcutSwitch.state = config.enabled ? .on : .off
        for (index, selected) in [config.control, config.option, config.shift, config.command].enumerated() {
            modifiers.setSelected(selected, forSegment: index)
        }
        modifiers.isEnabled = config.enabled
        shortcutKey.isEnabled = config.enabled
        shortcutKey.selectItem(withTitle: config.key)
        shortcutDetail.stringValue = shortcutError ?? (config.enabled ? "Active shortcut: \(shortcut.status)" : "Off. Default combination: \(config.displayName).")
        shortcutDetail.textColor = shortcutError == nil ? .secondaryLabelColor : .systemRed
    }

    private func refreshSavedDevices() {
        let choices = monitor.remembered.all().sorted {
            $0.value.deviceName.localizedStandardCompare($1.value.deviceName) == .orderedAscending
        }
        let signature = choices.map { "\($0.key):\($0.value.deviceName):\($0.value.microphone.rawValue)" }.joined(separator: "|")
        if signature != savedSignature || savedStack.arrangedSubviews.isEmpty {
            savedStack.arrangedSubviews.forEach { savedStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            if choices.isEmpty { savedStack.addArrangedSubview(note("No remembered devices yet. Check “Remember my choice for this device” the next time the popup appears.")) }
            for (key, choice) in choices {
                let name = NSTextField(wrappingLabelWithString: choice.deviceName)
                name.font = .systemFont(ofSize: 13, weight: .semibold)
                name.toolTip = choice.deviceName
                let popup = NSPopUpButton()
                popup.addItems(withTitles: ["Preferred microphone", "Bluetooth microphone"])
                popup.selectItem(at: choice.microphone == .preferred ? 0 : 1)
                popup.identifier = NSUserInterfaceItemIdentifier(key)
                popup.target = self
                popup.action = #selector(savedChoiceChanged(_:))
                popup.setAccessibilityLabel("Saved microphone for \(choice.deviceName)")
                let open = NSButton(title: "Open choice…", target: self, action: #selector(openSavedChoice(_:)))
                open.identifier = NSUserInterfaceItemIdentifier(key)
                let forget = NSButton(title: "Forget choice", target: self, action: #selector(forgetSavedChoice(_:)))
                forget.identifier = NSUserInterfaceItemIdentifier(key)
                popup.widthAnchor.constraint(equalToConstant: 230).isActive = true
                let row = stack([name, stack([popup, open, forget], vertical: false, spacing: 10), separator()],
                                vertical: true, spacing: 8)
                savedStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: savedStack.widthAnchor).isActive = true
            }
            savedSignature = signature
        }
        undoButton.isEnabled = monitor.undoableForget != nil
        undoButton.toolTip = monitor.undoableForget.map { "Restore the saved choice for \($0.choice.deviceName)" }
    }

    private func refreshStageFill() {
        let preferences = stageFill.preferences
        stageEnableSwitch.state = preferences.enabled ? .on : .off
        stagePerDisplaySwitch.state = preferences.rememberPerDisplay ? .on : .off
        let displays = StageDisplay.connected()
        let signature = displays.map { "\($0.key):\($0.name):\($0.visibleFrame)" }.joined(separator: "|")
        if signature != displaySignature {
            let previous = stageDisplayPopup.selectedItem?.representedObject as? String
            stageDisplayPopup.removeAllItems()
            for display in displays {
                let frame = display.visibleFrame
                stageDisplayPopup.addItem(withTitle:
                    "\(display.name) — \(Int(frame.width)) × \(Int(frame.height)) pt")
                stageDisplayPopup.lastItem?.representedObject = display.key
            }
            if let previous, let item = stageDisplayPopup.itemArray.first(where: {
                $0.representedObject as? String == previous
            }) { stageDisplayPopup.select(item) }
            displaySignature = signature
        }
        stageDisplayPopup.isHidden = !preferences.rememberPerDisplay
        stageDisplayPopup.isEnabled = preferences.enabled && !displays.isEmpty
        stageWidthField.isEnabled = preferences.enabled
        stageSaveWidthButton.isEnabled = preferences.enabled
        stageActionButton.isEnabled = preferences.enabled
        stagePerDisplaySwitch.isEnabled = preferences.enabled
        let displayKey = stageDisplayPopup.selectedItem?.representedObject as? String
        let width = preferences.reservation(for: displayKey ?? "")
        if stageWidthField.currentEditor() == nil { stageWidthField.stringValue = String(width) }
        stageWidthDescription.stringValue = "Leave \(width) screen points on the left. The app clamps this width on smaller displays; screen points adjust to display scaling."
        stagePermissionLabel.stringValue = AXIsProcessTrusted()
            ? "Access granted. Ready to resize other apps' windows."
            : "Accessibility access is required to move and resize other apps' windows. Microphone Choice continues to work without it."
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Microphone Choice", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Microphone")
        microphoneMenu.autoenablesItems = false
        microphoneMenu.delegate = self
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func preferredChanged() {
        let uid = preferredPopup.selectedItem?.representedObject as? String ?? ""
        monitor.settings.preferredInputUID = uid.isEmpty ? nil : uid
        monitor.settings.preferredInputName = uid.isEmpty ? nil : preferredPopup.titleOfSelectedItem
        monitor.preferenceChanged("Preferred microphone setting changed.")
    }
    @objc private func themeChanged() {
        let theme = AppTheme.allCases[themePopup.indexOfSelectedItem]
        monitor.settings.theme = theme
        NSApp.appearance = theme.appearance
        monitor.preferenceChanged("Appearance changed to \(theme.title).")
    }
    @objc private func loginChanged() {
        if let error = login.setEnabled(loginSwitch.state == .on) { showError(error) }
        monitor.preferenceChanged("Start at login is \(login.enabled ? "on" : "off").")
        refresh()
    }
    @objc private func notificationsChanged() {
        monitor.settings.notificationsEnabled = notificationSwitch.state == .on
        monitor.notifications.enabled = monitor.settings.notificationsEnabled
        if monitor.settings.notificationsEnabled && !monitor.preview { monitor.notifications.requestPermission() }
        monitor.preferenceChanged("Saved-choice notifications are \(monitor.settings.notificationsEnabled ? "on" : "off").")
    }
    @objc private func shortcutChanged() {
        let config = ShortcutConfiguration(enabled: shortcutSwitch.state == .on,
            control: modifiers.isSelected(forSegment: 0), option: modifiers.isSelected(forSegment: 1),
            shift: modifiers.isSelected(forSegment: 2), command: modifiers.isSelected(forSegment: 3),
            key: shortcutKey.titleOfSelectedItem ?? "M")
        shortcutError = shortcut.configure(config)
        if shortcutError == nil {
            monitor.settings.shortcut = config
            monitor.preferenceChanged(config.enabled ? "Keyboard shortcut changed to \(config.displayName)." : "Keyboard shortcut disabled.")
        }
        refresh()
    }
    @objc private func savedChoiceChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        monitor.changeSavedChoice(for: key, to: sender.indexOfSelectedItem == 0 ? .preferred : .bluetooth)
    }
    @objc private func openSavedChoice(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { monitor.requestChoice(for: key) }
    }
    @objc private func forgetSavedChoice(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { monitor.forgetChoice(for: key) }
    }
    @objc private func undoForget() { monitor.undoForget() }
    @objc private func tabChanged() { selectPanel(tabs.selectedSegment) }
    @objc private func openSettings() { showSettings(tab: 0) }
    @objc private func openSavedDevices() { showSettings(tab: 1) }
    @objc private func openDiagnostics() { showSettings(tab: 2) }
    @objc private func openStageSettings() { showSettings(tab: 3) }
    @objc private func stageEnabledChanged() {
        stageFill.preferences.enabled = stageEnableSwitch.state == .on
        refresh()
    }
    @objc private func stagePerDisplayChanged() {
        stageFill.preferences.rememberPerDisplay = stagePerDisplaySwitch.state == .on
        refresh()
    }
    @objc private func stageDisplayChanged() {
        stageWidthField.window?.makeFirstResponder(nil)
        refreshStageFill()
    }
    @objc private func saveStageWidth() {
        let text = stageWidthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let width = Int(text), 0...StageFillPreferences.maximumReservation ~= width else {
            stageResultLabel.stringValue = "Enter a whole number from 0 to \(StageFillPreferences.maximumReservation)."
            stageResultLabel.textColor = .systemRed
            return
        }
        let displayKey = stageDisplayPopup.selectedItem?.representedObject as? String
        stageFill.preferences.setReservation(width, for: displayKey)
        stageResultLabel.stringValue = "Reserved width saved."
        stageResultLabel.textColor = .secondaryLabelColor
        stageWidthField.window?.makeFirstResponder(nil)
        refreshStageFill()
    }
    @objc private func checkStageAccess() { refreshStageFill() }
    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    @objc private func fillStageManager() {
        switch stageFill.fillFocusedWindow() {
        case .filled(let display, _, _):
            stageResultLabel.stringValue = "Filled the window on \(display)."
            stageResultLabel.textColor = .secondaryLabelColor
        case .needsAccessibility:
            stageResultLabel.stringValue = "Grant Accessibility access, then choose Stage Manager Fill again."
            stageResultLabel.textColor = .systemRed
            showSettings(tab: 3)
        case .unavailable(let reason):
            stageResultLabel.stringValue = reason
            stageResultLabel.textColor = .systemRed
            showSettings(tab: 3)
        }
    }
    @objc private func usePreferred() { monitor.usePreferredInput() }
    @objc private func selectInputFromMenu(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { monitor.switchInput(to: uid) }
    }
    @objc private func openChoiceFromMenu(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { monitor.requestChoice(for: key) }
    }
    @objc private func testPopup() { monitor.testPopup() }
    @objc private func refreshDiagnostics() {
        monitor.scan()
        if !monitor.preview { monitor.notifications.refreshPermission() }
    }
    @objc private func copyReport(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(monitor.diagnosticReport(shortcutStatus: shortcut.status), forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak sender] in sender?.title = "Copy report" }
    }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func openNotificationSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    @objc private func quit() { login.quit() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: 0)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onTermination?() }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not update the setting"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = settingsWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    private func item(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }
    private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            for view in views where view is NSTextField || view is NSBox {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }
    private func switchRow(_ control: NSSwitch, title: String, trailing: NSView? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        let spacer = NSView()
        let row = stack([control, label, spacer] + (trailing.map { [$0] } ?? []), vertical: false, spacing: 8)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }
    private func note(_ text: String) -> NSTextField { secondary(NSTextField(wrappingLabelWithString: text)) }
    private func secondary(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
    private func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}
