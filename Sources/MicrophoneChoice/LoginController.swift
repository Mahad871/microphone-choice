import AppKit
import Darwin
import Foundation
import ServiceManagement

final class LoginController {
    private let settings: AppSettings
    private let homebrewManaged: Bool
    private let preview: Bool
    private let serviceLabel = "sh.brew.microphone-choice"
    private var serviceTarget: String { "gui/\(getuid())/\(serviceLabel)" }

    static var existingHomebrewServiceMatchesApp: Bool {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/sh.brew.microphone-choice.plist")
        guard let data = try? Data(contentsOf: agent),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = (plist["ProgramArguments"] as? [String])?.first,
              let current = Bundle.main.executableURL else { return false }
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath() == current.resolvingSymlinksInPath()
    }

    init(settings: AppSettings, homebrewManaged: Bool, preview: Bool = false) {
        self.settings = settings
        self.homebrewManaged = homebrewManaged
        self.preview = preview
    }

    var enabled: Bool {
        if preview { return settings.startAtLogin }
        if homebrewManaged {
            let result = launchctl(["print-disabled", "gui/\(getuid())"])
            guard result.status == 0 else { return settings.startAtLogin }
            return !LaunchAgentStatus.isDisabled(in: result.output, label: serviceLabel)
        }
        return SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    var detail: String {
        if !homebrewManaged && !preview && SMAppService.mainApp.status == .requiresApproval {
            return "Approval is needed in System Settings → General → Login Items."
        }
        return "Turning this off keeps the app open until you quit."
    }

    func configureInitialLogin() {
        guard !preview else { return }
        if homebrewManaged {
            // One installation method owns startup; remove a legacy direct-app registration.
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            return
        }
        guard settings.startAtLogin,
              SMAppService.mainApp.status == .notRegistered else { return }
        do { try SMAppService.mainApp.register() }
        catch { log("Could not register login item: \(error.localizedDescription)") }
    }

    func setEnabled(_ enabled: Bool) -> String? {
        if preview { settings.startAtLogin = enabled; return nil }
        if homebrewManaged {
            let result = launchctl([enabled ? "enable" : "disable", serviceTarget])
            guard result.status == 0 else { return "Could not update start at login. \(result.output)" }
        } else {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } catch { return error.localizedDescription }
        }
        settings.startAtLogin = enabled
        return nil
    }

    func quit() {
        // Unload the current Homebrew job so KeepAlive does not immediately reopen the app.
        // Its launch-agent file and login preference are retained for the next login.
        if homebrewManaged && !preview {
            if launchctl(["print", serviceTarget]).status == 0 {
                let result = launchctl(["bootout", serviceTarget])
                if result.status != 0 {
                    let alert = NSAlert()
                    alert.messageText = "Could not quit Microphone Choice"
                    alert.informativeText = "The background service could not be stopped. \(result.output)"
                    alert.runModal()
                    return
                }
            }
            NSApp.terminate(nil)
        } else { NSApp.terminate(nil) }
    }

    private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
}
