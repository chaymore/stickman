import AppKit
import CoreGraphics

enum ScreenshotCaptureError: LocalizedError {
    case captureFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            return "I could not capture the screen. macOS may need Screen Recording permission for Stickman or Terminal."
        case .pngEncodingFailed:
            return "I captured the screen, but could not encode the screenshot."
        }
    }
}

final class ScreenshotCaptureService {
    static let shared = ScreenshotCaptureService()

    private init() {}

    func captureMainDisplay() throws -> ScreenshotAttachment {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stickman-screenshot-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", "1", "-t", "png", url.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ScreenshotCaptureError.captureFailed
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw ScreenshotCaptureError.captureFailed
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }

        try? FileManager.default.removeItem(at: url)

        let base64 = data.base64EncodedString()
        return ScreenshotAttachment(
            dataURL: "data:image/png;base64,\(base64)",
            capturedAt: Date()
        )
    }

    func captureMainDisplayForNavigation() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotCaptureError.captureFailed
        }
    }
}
