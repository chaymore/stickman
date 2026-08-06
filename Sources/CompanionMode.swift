import AppKit

enum StickmanMetrics {
    static let designSize: CGFloat = 160
    static let characterSize: CGFloat = 112
}

enum StickmanMode: String, Codable {
    case peaceful
    case sparring

    var displayName: String {
        switch self {
        case .peaceful: return "Peaceful"
        case .sparring: return "Sparring"
        }
    }
}

enum StickmanCombatMove {
    case guardStance
    case dodge(direction: CGFloat)
    case jab
    case kick
    case lasso
    case groundSlam
    case hit(direction: CGVector)
    case victory
}

struct ScreenGuidanceMarker {
    let normalizedPoint: CGPoint
    let label: String
}

extension Notification.Name {
    static let stickmanModeDidChange = Notification.Name("StickmanModeDidChange")
    static let stickmanQuickAssistRequested = Notification.Name("StickmanQuickAssistRequested")
    static let stickmanScreenGuidanceRequested = Notification.Name("StickmanScreenGuidanceRequested")
}

final class StickmanModeController {
    static let shared = StickmanModeController()

    private(set) var mode: StickmanMode = .peaceful

    private init() {}

    func beginSparringFromTripleClick() {
        transition(to: .sparring, reason: "triple click challenge")
    }

    @discardableResult
    func setMode(_ newMode: StickmanMode, reason: String = "") -> Bool {
        guard newMode != .sparring else { return false }
        return transition(to: newMode, reason: reason)
    }

    @discardableResult
    private func transition(to newMode: StickmanMode, reason: String) -> Bool {
        guard mode != newMode else { return false }
        mode = newMode
        NotificationCenter.default.post(
            name: .stickmanModeDidChange,
            object: self,
            userInfo: ["mode": newMode.rawValue, "reason": reason]
        )
        return true
    }

    func toggle(reason: String = "shortcut") {
        if mode == .sparring {
            setMode(.peaceful, reason: reason)
        }
    }
}
