import Foundation
import UserNotifications

final class ChoiceNotifications: NSObject, UNUserNotificationCenterDelegate {
    var enabled = true
    private(set) var permissionStatus = "Checking permission…"
    var onStatusChanged: (() -> Void)?
    var onChangeChoice: ((String) -> Void)? {
        didSet {
            guard let onChangeChoice else { return }
            pendingChangeKeys.forEach(onChangeChoice)
            pendingChangeKeys.removeAll()
        }
    }

    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "remembered-microphone-choice"
    private let changeActionIdentifier = "change-microphone-choice"
    private var pendingChangeKeys: [String] = []

    func start() {
        center.delegate = self
        let changeAction = UNNotificationAction(identifier: changeActionIdentifier,
                                                title: "Change choice", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryIdentifier,
                                              actions: [changeAction], intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        refreshPermission()
    }

    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional: self.permissionStatus = "Allowed by macOS"
                case .notDetermined: self.permissionStatus = "Permission has not been requested"
                default: self.permissionStatus = "Disabled in macOS notification settings"
                }
                self.onStatusChanged?()
            }
        }
    }

    func requestPermission() {
        guard enabled else { return }
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { notificationLog("Notification permission failed: \(error.localizedDescription)") }
            else if !granted { notificationLog("Notifications are disabled; saved choices still apply") }
            self.refreshPermission()
        }
    }

    func showAppliedChoice(_ choice: RememberedChoice, for key: String, preferredName: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        switch choice.microphone {
        case .preferred:
            content.title = "Using \(preferredName)"
        case .bluetooth:
            content.title = "Using \(choice.deviceName) microphone"
        }
        content.body = "Applied your saved choice for \(choice.deviceName)."
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = "microphone-choice"
        content.userInfo = ["deviceKey": key]

        let identifier = "saved-choice-\(key)"
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.post(content, identifier: identifier)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert]) { granted, error in
                    if granted { self.post(content, identifier: identifier) }
                    else {
                        let reason = error?.localizedDescription ?? "permission denied"
                        notificationLog("Saved-choice notification unavailable: \(reason)")
                    }
                }
            default:
                notificationLog("Saved-choice notification unavailable: permission denied")
            }
        }
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        guard enabled else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { notificationLog("Could not show saved-choice notification: \(error.localizedDescription)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == changeActionIdentifier ||
                response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let key = response.notification.request.content.userInfo["deviceKey"] as? String
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let onChangeChoice { onChangeChoice(key) }
            else { pendingChangeKeys.append(key) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

private func notificationLog(_ message: String) {
    guard let data = "\(Date()): \(message)\n".data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}
