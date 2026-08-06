import AppKit
import ImageIO
import UniformTypeIdentifiers

enum StickmanAvatarPreviewRenderer {
    static func render(to outputURL: URL) throws {
        let bitmap = try renderSheet(frameTimeOffset: 0, titleSuffix: "Preview")
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
    }

    static func renderAnimation(to outputURL: URL) throws {
        let frameCount = 36
        let frameDuration = 1.0 / 12.0
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw PreviewError.encodingFailed
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDuration
            ]
        ]

        for frameIndex in 0 ..< frameCount {
            let bitmap = try renderSheet(
                frameTimeOffset: TimeInterval(frameIndex) * frameDuration,
                titleSuffix: "Animated Preview"
            )
            guard let cgImage = bitmap.cgImage else {
                throw PreviewError.encodingFailed
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw PreviewError.encodingFailed
        }
    }

    private static func renderSheet(frameTimeOffset: TimeInterval, titleSuffix: String) throws -> NSBitmapImageRep {
        let states = StickmanView.PreviewState.allCases
        let frameTimes: [TimeInterval] = [0.15, 0.55, 1.05, 1.55, 2.15]
        let avatarSize = NSSize(width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize)
        let labelWidth: CGFloat = 128
        let cellWidth: CGFloat = 178
        let rowHeight: CGFloat = 190
        let topPadding: CGFloat = 52
        let sidePadding: CGFloat = 22
        let imageSize = NSSize(
            width: sidePadding * 2 + labelWidth + cellWidth * CGFloat(frameTimes.count),
            height: topPadding + rowHeight * CGFloat(states.count) + 24
        )

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(imageSize.width),
                pixelsHigh: Int(imageSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [.alphaFirst],
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            throw PreviewError.encodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.translateBy(x: 0, y: imageSize.height)
        graphicsContext.cgContext.scaleBy(x: 1, y: -1)
        defer { NSGraphicsContext.restoreGraphicsState() }

        AnthropicStyle.panel.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        drawTitle(in: imageSize, titleSuffix: titleSuffix)

        for (rowIndex, state) in states.enumerated() {
            let rowY = topPadding + CGFloat(rowIndex) * rowHeight
            drawStateLabel(state, rowY: rowY, sidePadding: sidePadding)
            drawRowGuide(rowY: rowY, imageWidth: imageSize.width, sidePadding: sidePadding)

            for (frameIndex, time) in frameTimes.enumerated() {
                let x = sidePadding + labelWidth + CGFloat(frameIndex) * cellWidth
                drawAvatarFrame(
                    state: state,
                    time: time + frameTimeOffset,
                    displayTime: time,
                    at: CGPoint(x: x, y: rowY + 14),
                    size: avatarSize
                )
            }
        }

        return bitmap
    }

    private static func drawTitle(in imageSize: NSSize, titleSuffix: String) {
        let title = "Stickman Stickman Native Animation \(titleSuffix)"
        let subtitle = "Rows are states; columns are sampled moments from each loop."
        drawText(
            title,
            at: CGPoint(x: 22, y: 14),
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
        drawText(
            subtitle,
            at: CGPoint(x: imageSize.width - 392, y: 18),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: AnthropicStyle.mutedInk
            ]
        )
    }

    private static func drawStateLabel(_ state: StickmanView.PreviewState, rowY: CGFloat, sidePadding: CGFloat) {
        drawText(
            state.title,
            at: CGPoint(x: sidePadding, y: rowY + 68),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: AnthropicStyle.ink
            ]
        )
    }

    private static func drawRowGuide(rowY: CGFloat, imageWidth: CGFloat, sidePadding: CGFloat) {
        AnthropicStyle.line.withAlphaComponent(0.42).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: sidePadding, y: rowY + 178))
        path.line(to: CGPoint(x: imageWidth - sidePadding, y: rowY + 178))
        path.lineWidth = 1
        path.stroke()
    }

    private static func drawAvatarFrame(
        state: StickmanView.PreviewState,
        time: TimeInterval,
        displayTime: TimeInterval,
        at origin: CGPoint,
        size: NSSize
    ) {
        let frameRect = NSRect(origin: origin, size: size)
        AnthropicStyle.inset.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: frameRect.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10).fill()

        let view = StickmanView(frame: NSRect(origin: .zero, size: size))
        view.setPreviewState(state, time: time)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: origin.x, y: origin.y)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        drawText(
            String(format: "%.2fs", displayTime),
            at: CGPoint(x: origin.x + 62, y: origin.y + 164),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: AnthropicStyle.mutedInk
            ]
        )
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let size = text.size(withAttributes: attributes)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y + size.height)
        context.scaleBy(x: 1, y: -1)
        text.draw(at: .zero, withAttributes: attributes)
        context.restoreGState()
    }

    enum PreviewError: Error {
        case encodingFailed
    }
}
