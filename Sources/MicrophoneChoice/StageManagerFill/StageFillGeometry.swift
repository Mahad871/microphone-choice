import AppKit
import ColorSync

/// Both AppKit and Accessibility use logical screen points. AX's origin is at
/// the top of the primary display; AppKit's is at its bottom.
struct StageDisplay {
    let key: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect

    static func connected() -> [StageDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let identifier = number.uint32Value
            let key: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(identifier)?.takeRetainedValue(),
               let description = CFUUIDCreateString(nil, uuid) {
                key = description as String
            } else {
                key = "display-\(identifier)"
            }
            return StageDisplay(key: key, name: screen.localizedName,
                                frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

enum StageFillGeometry {
    static func coversEntireDisplay(_ axWindow: CGRect, display: StageDisplay,
                                    primaryTop: CGFloat) -> Bool {
        // There is no documented cross-app AX full-screen flag. Conservatively
        // skip windows covering the raw display, while allowing Apple's normal
        // Fill state, which covers the smaller visibleFrame.
        let displayAX = axFrame(fromAppKit: display.frame, primaryTop: primaryTop)
        return abs(axWindow.minX - displayAX.minX) < 3 &&
            abs(axWindow.minY - displayAX.minY) < 3 &&
            abs(axWindow.width - displayAX.width) < 3 &&
            abs(axWindow.height - displayAX.height) < 3
    }

    static func appKitFrame(fromAX ax: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryTop - ax.maxY, width: ax.width, height: ax.height)
    }

    static func axFrame(fromAppKit frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY,
               width: frame.width, height: frame.height)
    }

    static func displayContainingMost(of axWindow: CGRect, displays: [StageDisplay],
                                        primaryTop: CGFloat) -> StageDisplay? {
        let appKitWindow = appKitFrame(fromAX: axWindow, primaryTop: primaryTop)
        var selected: StageDisplay?
        var largestOverlap: CGFloat = 0
        for display in displays {
            let intersection = appKitWindow.intersection(display.frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > largestOverlap {
                selected = display
                largestOverlap = area
            }
        }
        return selected
    }

    static func targetFrame(for display: StageDisplay, reservation: Int,
                            primaryTop: CGFloat) -> CGRect {
        let visible = display.visibleFrame
        // Keep a useful window even on a very small display. The real app may
        // impose a larger minimum; the AX readback reports that constraint.
        let minimumWidth = min(320, floor(visible.width / 2))
        let left = min(CGFloat(max(0, reservation)), max(0, visible.width - minimumWidth))
        let appKitTarget = CGRect(x: visible.minX + left, y: visible.minY,
                                  width: visible.width - left, height: visible.height)
        return axFrame(fromAppKit: appKitTarget, primaryTop: primaryTop)
    }
}
