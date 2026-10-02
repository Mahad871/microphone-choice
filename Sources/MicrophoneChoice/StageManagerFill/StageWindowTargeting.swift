import AppKit
import ApplicationServices

struct StageWindowTarget {
    let window: AXUIElement
    let pid: pid_t
    let greenButton: CGRect
    let frame: CGRect
}

enum StageWindowTargeting {
    static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    static func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let result = value(name, of: element),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: element),
              let size = value(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func target(window: AXUIElement, pid: pid_t) -> StageWindowTarget? {
        AXUIElementSetMessagingTimeout(window, 0.03)
        guard value(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole,
              value(kAXMinimizedAttribute, of: window) as? Bool != true,
              let windowFrame = frame(of: window),
              let green = element(kAXFullScreenButtonAttribute, of: window)
                ?? element(kAXZoomButtonAttribute, of: window),
              let greenFrame = frame(of: green), !greenFrame.isEmpty,
              windowFrame.insetBy(dx: -1, dy: -1).contains(greenFrame) else { return nil }
        return StageWindowTarget(window: window, pid: pid,
                                 greenButton: greenFrame, frame: windowFrame)
    }

    static func focused(pid: pid_t) -> StageWindowTarget? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.03)
        guard let window = element(kAXFocusedWindowAttribute, of: app) else { return nil }
        return target(window: window, pid: pid)
    }

    static func titleBar(at point: CGPoint, pid: pid_t) -> StageWindowTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.03)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner == pid else { return nil }
        let role = value(kAXRoleAttribute, of: hit) as? String
        guard let window = role == kAXWindowRole ? hit : element(kAXWindowAttribute, of: hit),
              let target = target(window: window, pid: pid) else { return nil }
        // Use the actual traffic-light row, not a guessed 60px toolbar area.
        // Custom tabs, web content, search fields, and buttons fail this check.
        let titleRow = CGRect(x: target.frame.minX, y: target.frame.minY,
                              width: target.frame.width,
                              height: target.greenButton.maxY - target.frame.minY + 5)
        guard titleRow.contains(point), !target.greenButton.insetBy(dx: -4, dy: -4).contains(point)
        else { return nil }
        let title = element(kAXTitleUIElementAttribute, of: window)
        guard role == kAXWindowRole || role == kAXToolbarRole ||
                (title.map { CFEqual($0, hit) } ?? false) else { return nil }
        return target
    }
}
