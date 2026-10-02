import AppKit
import ApplicationServices

enum StageFillOutcome {
    case filled(display: String, requested: CGRect, actual: CGRect)
    case needsAccessibility
    case unavailable(String)
}

final class StageFillWindowManager {
    func fillFocusedWindow(of pid: pid_t, preferences: StageFillPreferences) -> StageFillOutcome {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let window = value as! AXUIElement? else {
            return .unavailable("The selected app has no focused window to resize.")
        }
        AXUIElementSetMessagingTimeout(window, 2)
        guard stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole as String,
              stringAttribute(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String
        else { return .unavailable("Only standard app windows can be resized.") }
        if boolAttribute(kAXMinimizedAttribute, of: window) == true {
            return .unavailable("Restore the minimized window before filling it.")
        }
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            var isSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, attribute as CFString, &isSettable) == .success,
                  isSettable.boolValue else {
                return .unavailable("This app does not allow its window to be resized or moved.")
            }
        }
        guard let original = frame(of: window), let primaryTop = NSScreen.screens.first?.frame.maxY else {
            return .unavailable("The window frame or screen geometry is unavailable.")
        }
        guard let display = StageFillGeometry.displayContainingMost(
            of: original, displays: StageDisplay.connected(), primaryTop: primaryTop
        ) else { return .unavailable("The window is not on a connected display.") }
        if StageFillGeometry.coversEntireDisplay(original, display: display, primaryTop: primaryTop) {
            return .unavailable("This window appears to be in native full screen. Leave full screen first.")
        }
        let target = StageFillGeometry.targetFrame(
            for: display, reservation: preferences.reservation(for: display.key), primaryTop: primaryTop
        )
        if target.width >= original.width && target.height >= original.height {
            // Moving with the old size first avoids the window server clipping
            // a large resize against the old origin (observed in Finder/Safari).
            let positioned = CGRect(origin: target.origin, size: original.size)
            guard setFrame(positioned, of: window) else {
                _ = setFrame(original, of: window)
                return .unavailable("The app refused to move its window.")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard setFrame(target, of: window) else {
            _ = setFrame(original, of: window)
            return .unavailable("The app refused to move or resize its window.")
        }
        // Finder and Safari animate AX frame writes. Reading repeatedly during
        // the animation can itself return intermediate constrained frames.
        Thread.sleep(forTimeInterval: 0.8)
        guard let actual = frame(of: window) else {
            return .unavailable("The app did not report its new window size.")
        }
        if !matches(actual, target) {
            _ = setFrame(original, of: window)
            Thread.sleep(forTimeInterval: 0.8)
            let restored = frame(of: window).map { matches($0, original) } ?? false
            return .unavailable(restored
                ? "The app limited the window size. Its minimum or aspect ratio may prevent an exact fill."
                : "The app limited the window size and did not fully restore its previous frame.")
        }
        return .filled(display: display.name, requested: target, actual: actual)
    }

    private func matches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= 3 &&
            abs(actual.minY - requested.minY) <= 3 &&
            abs(actual.width - requested.width) <= 3 &&
            abs(actual.height - requested.height) <= 3
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position = position as! AXValue?, let size = size as! AXValue? else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ rect: CGRect, of window: AXUIElement) -> Bool {
        var position = rect.origin
        var size = rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let current = frame(of: window)
        let shrinking = current.map { rect.width < $0.width || rect.height < $0.height } ?? false
        // Large sizes can be clipped against the current origin. Move first
        // when growing; shrink first when restoring, then move the window.
        if shrinking {
            guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                                sizeValue) == .success else { return false }
            Thread.sleep(forTimeInterval: 0.2)
            guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                                positionValue) == .success else { return false }
        } else {
            guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                                positionValue) == .success,
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                                sizeValue) == .success else { return false }
        }
        return true
    }
}
