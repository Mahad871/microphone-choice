import Foundation

/// Only intercept the second click of an ordinary, stationary double-click.
/// Eligibility of the actual AX element is checked separately before swallowing.
struct StageClickSequence {
    private var firstPoint: CGPoint?
    private var firstTime: TimeInterval = 0

    mutating func down(at point: CGPoint, time: TimeInterval, count: Int,
                       unmodified: Bool, interval: TimeInterval) -> Bool {
        defer {
            firstPoint = count == 1 && unmodified ? point : nil
            firstTime = time
        }
        guard count == 2, unmodified, let firstPoint,
              time >= firstTime, time - firstTime <= interval + 0.05 else { return false }
        return hypot(point.x - firstPoint.x, point.y - firstPoint.y) <= 5
    }
}

enum StageCompanionGeometry {
    /// AppKit coordinates. Keep the control on the title-bar row so Apple's
    /// own hover menu remains below it. Do not cover the traffic-light buttons.
    static func frame(beside button: CGRect, visible: CGRect) -> CGRect? {
        let frame = CGRect(x: button.maxX + 10, y: button.midY - 18,
                           width: 198, height: 36)
        guard frame.maxX <= visible.maxX - 6 else { return nil }
        return CGRect(x: frame.minX,
                      y: min(max(frame.minY, visible.minY + 4), visible.maxY - frame.height),
                      width: frame.width, height: frame.height)
    }
}
