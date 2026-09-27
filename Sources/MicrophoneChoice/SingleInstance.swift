import Darwin
import Foundation

let showSettingsNotification = Notification.Name("io.github.mahad871.microphonechoice.showSettings")

final class SingleInstance {
    private var descriptor: Int32 = -1
    let acquired: Bool

    init(directory customDirectory: URL? = nil) {
        let directory = customDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Microphone Choice", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            acquired = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
        } catch {
            acquired = false
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
