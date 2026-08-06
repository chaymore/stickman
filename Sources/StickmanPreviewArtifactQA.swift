import Foundation
import ImageIO

enum StickmanPreviewArtifactQA {
    static func run(root: URL) throws {
        let previewRoot = root.appendingPathComponent("DesignConcepts/StickmanPreview", isDirectory: true)
        let checks = [
            ImageCheck(
                label: "Avatar states PNG",
                url: previewRoot.appendingPathComponent("avatar-states.png"),
                expectedWidth: 1062,
                expectedHeight: 1976,
                expectedFrameCount: 1
            ),
            ImageCheck(
                label: "Avatar states GIF",
                url: previewRoot.appendingPathComponent("avatar-states.gif"),
                expectedWidth: 1062,
                expectedHeight: 1976,
                expectedFrameCount: 36
            ),
            ImageCheck(
                label: "Window preview PNG",
                url: previewRoot.appendingPathComponent("window-preview.png"),
                expectedWidth: 1076,
                expectedHeight: 526,
                expectedFrameCount: 1
            ),
            ImageCheck(
                label: "Reference comparison PNG",
                url: previewRoot.appendingPathComponent("reference-comparison.png"),
                expectedWidth: 920,
                expectedHeight: 560,
                expectedFrameCount: 1
            )
        ]

        for check in checks {
            try validate(check)
        }
    }

    private static func validate(_ check: ImageCheck) throws {
        guard FileManager.default.fileExists(atPath: check.url.path) else {
            throw QAError.missing(check.url.path)
        }

        guard let source = CGImageSourceCreateWithURL(check.url as CFURL, nil) else {
            throw QAError.unreadable(check.url.path)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw QAError.unreadable(check.url.path)
        }

        guard width == check.expectedWidth, height == check.expectedHeight else {
            throw QAError.dimensionMismatch(
                path: check.url.path,
                actual: "\(width)x\(height)",
                expected: "\(check.expectedWidth)x\(check.expectedHeight)"
            )
        }

        guard frameCount == check.expectedFrameCount else {
            throw QAError.frameCountMismatch(
                path: check.url.path,
                actual: frameCount,
                expected: check.expectedFrameCount
            )
        }

        print("OK \(check.label): \(width)x\(height), \(frameCount) frame\(frameCount == 1 ? "" : "s")")
    }

    private struct ImageCheck {
        let label: String
        let url: URL
        let expectedWidth: Int
        let expectedHeight: Int
        let expectedFrameCount: Int
    }

    enum QAError: LocalizedError {
        case missing(String)
        case unreadable(String)
        case dimensionMismatch(path: String, actual: String, expected: String)
        case frameCountMismatch(path: String, actual: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "Missing preview artifact: \(path)"
            case .unreadable(let path):
                return "Preview artifact is not decodable: \(path)"
            case .dimensionMismatch(let path, let actual, let expected):
                return "Preview artifact has wrong dimensions: \(path) is \(actual), expected \(expected)"
            case .frameCountMismatch(let path, let actual, let expected):
                return "Preview artifact has wrong frame count: \(path) has \(actual), expected \(expected)"
            }
        }
    }
}
