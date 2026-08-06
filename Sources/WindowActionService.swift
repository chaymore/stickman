import AppKit
import ApplicationServices

final class WindowActionService {
    static let shared = WindowActionService()

    enum Placement: Equatable {
        case leftHalf
        case rightHalf
        case center
        case maximize
        case minimize
    }

    private init() {}

    func placeFrontWindow(_ placement: Placement) -> String {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return "Give Stickman Accessibility permission in System Settings, then try that window command again."
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "I could not find a frontmost app window."
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value as! AXUIElement?
        else {
            return "I could not find a movable window in \(app.localizedName ?? "that app")."
        }

        if placement == .minimize {
            let minimized = kCFBooleanTrue!
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized)
            return result == .success ? "Minimized the current window." : "That window would not minimize."
        }

        guard let screen = NSScreen.main else { return "I could not read the display bounds." }
        let visible = screen.visibleFrame
        let globalTop = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        let quartzVisible = CGRect(
            x: visible.minX,
            y: globalTop - visible.maxY,
            width: visible.width,
            height: visible.height
        )

        let target: CGRect
        switch placement {
        case .leftHalf:
            target = CGRect(x: quartzVisible.minX, y: quartzVisible.minY, width: quartzVisible.width / 2, height: quartzVisible.height)
        case .rightHalf:
            target = CGRect(x: quartzVisible.midX, y: quartzVisible.minY, width: quartzVisible.width / 2, height: quartzVisible.height)
        case .maximize:
            target = quartzVisible
        case .center:
            let size = currentSize(of: window) ?? CGSize(width: quartzVisible.width * 0.72, height: quartzVisible.height * 0.78)
            target = CGRect(
                x: quartzVisible.midX - size.width / 2,
                y: quartzVisible.midY - size.height / 2,
                width: min(size.width, quartzVisible.width),
                height: min(size.height, quartzVisible.height)
            )
        case .minimize:
            return ""
        }

        var position = target.origin
        var size = target.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return "I could not prepare that window move." }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard positionResult == .success, sizeResult == .success else {
            return "That app did not allow Stickman to resize its current window."
        }
        return "Moved the current window."
    }

    private func currentSize(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value as! AXValue?, AXValueGetType(axValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
