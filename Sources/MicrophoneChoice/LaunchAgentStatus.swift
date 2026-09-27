import Foundation

enum LaunchAgentStatus {
    static func isDisabled(in output: String, label: String) -> Bool {
        output.split(separator: "\n").contains { line in
            guard line.contains("\"\(label)\"") else { return false }
            let value = line.split(separator: ">", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
            // launchctl uses booleans on older macOS and words on newer releases.
            return value == "true" || value == "disabled"
        }
    }
}
