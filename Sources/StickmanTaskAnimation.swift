import Foundation

enum StickmanTaskAnimation: String {
    case spawnAgent
    case openBrowserTab
    case checkCalendar
    case requestPermission
    case connectService
}

extension Notification.Name {
    static let stickmanTaskAnimationRequested = Notification.Name("StickmanTaskAnimationRequested")
}

@MainActor
enum StickmanTaskAnimationController {
    static func play(_ animation: StickmanTaskAnimation) {
        NotificationCenter.default.post(
            name: .stickmanTaskAnimationRequested,
            object: nil,
            userInfo: ["animation": animation.rawValue]
        )
    }
}
