import Foundation

/// A restore frame is valid only while the window remains where we filled it.
/// A manual move or resize becomes the starting point for the next fill.
struct StageRestoreState {
    let original: CGRect
    let filled: CGRect

    func restoreFrame(current: CGRect) -> CGRect? {
        Self.matches(current, filled) ? original : nil
    }

    static func matches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= 3 &&
            abs(actual.minY - requested.minY) <= 3 &&
            abs(actual.width - requested.width) <= 3 &&
            abs(actual.height - requested.height) <= 3
    }
}
